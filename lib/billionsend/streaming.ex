defmodule BillionSend.InboxStreamEvent do
  @moduledoc """
  One inbox event: the webhook event of the same name, wrapped.

    * `id` - the stream position after this event (resume from it with `last_event_id:`)
    * `event` - the event name, such as `"inbox.email.received"`
    * `data` - a map with `"type"`, `"created_at"`, `"inbox_id"` (nil for an
      email.received that reached no inbox) and the webhook payload's `"data"`
  """
  defstruct [:id, :event, :data]
  @type t :: %__MODULE__{id: String.t(), event: String.t(), data: map()}
end

defmodule BillionSend.StreamGapEvent do
  @moduledoc """
  Events may have been lost before this point: catch up through the REST lists.
  `data["reason"]` says why (`"retention"`: the position is over 24 hours old).
  """
  defstruct id: nil, event: "stream.gap", data: %{}
  @type t :: %__MODULE__{id: nil, event: String.t(), data: map()}
end

defmodule BillionSend.SSEDecoder do
  @moduledoc """
  Incremental parser of the `text/event-stream` format.

  Lines may end in CRLF, LF or CR and may be split anywhere across chunks;
  comment lines are skipped; several data lines join with newlines. Each event
  comes out as `%{id: last id seen, event: name, data: parsed JSON or raw text}`.
  """

  defstruct buffer: "",
            started: false,
            after_cr: false,
            data: [],
            event: "",
            last_event_id: nil,
            retry_ms: nil

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  @doc "Feeds one chunk; returns the events it completed and the new decoder."
  @spec feed(t(), binary()) :: {[map()], t()}
  def feed(%__MODULE__{} = d, chunk) do
    chunk =
      if not d.started and chunk != "",
        do: String.replace_prefix(chunk, "﻿", ""),
        else: chunk

    d = if chunk != "", do: %{d | started: true}, else: d

    {chunk, d} =
      if d.after_cr and chunk != "" do
        # The previous chunk ended in CR: a LF here completes that CRLF.
        {String.replace_prefix(chunk, "\n", ""), %{d | after_cr: false}}
      else
        {chunk, d}
      end

    lines(%{d | buffer: d.buffer <> chunk}, [])
  end

  defp lines(d, events) do
    case :binary.match(d.buffer, ["\r", "\n"]) do
      :nomatch ->
        {Enum.reverse(events), d}

      {index, 1} ->
        size = byte_size(d.buffer)
        line = binary_part(d.buffer, 0, index)

        {skip, after_cr} =
          case binary_part(d.buffer, index, 1) do
            "\r" when index + 1 == size -> {1, true}
            "\r" -> if binary_part(d.buffer, index + 1, 1) == "\n", do: {2, false}, else: {1, false}
            "\n" -> {1, false}
          end

        rest = binary_part(d.buffer, index + skip, size - index - skip)
        d = %{d | buffer: rest, after_cr: after_cr or d.after_cr}

        case line(d, line) do
          {nil, d} -> lines(d, events)
          {event, d} -> lines(d, [event | events])
        end
    end
  end

  defp line(d, ""), do: dispatch(d)
  defp line(d, ":" <> _), do: {nil, d}

  defp line(d, text) do
    {name, value} =
      case String.split(text, ":", parts: 2) do
        [name, value] -> {name, String.replace_prefix(value, " ", "")}
        [name] -> {name, ""}
      end

    d =
      case name do
        "data" ->
          %{d | data: [value | d.data]}

        "event" ->
          %{d | event: value}

        "id" ->
          if String.contains?(value, <<0>>), do: d, else: %{d | last_event_id: value}

        "retry" ->
          if value =~ ~r/\A[0-9]+\z/, do: %{d | retry_ms: String.to_integer(value)}, else: d

        _ ->
          d
      end

    {nil, d}
  end

  defp dispatch(%{data: []} = d), do: {nil, %{d | event: ""}}

  defp dispatch(d) do
    raw = d.data |> Enum.reverse() |> Enum.join("\n")

    data =
      case JSON.decode(raw) do
        {:ok, value} -> value
        {:error, _} -> raw
      end

    event = %{
      id: d.last_event_id,
      event: if(d.event == "", do: "message", else: d.event),
      data: data
    }

    {event, %{d | data: [], event: ""}}
  end
end

defmodule BillionSend.EventStream do
  @moduledoc """
  A server-sent event stream (`text/event-stream`) of inbox events.

  `BillionSend.Inboxes.Events.stream/2` and `stream_inbox/3` open it, so a
  refused stream is an `{:error, error}` at once; the stream they return is a
  lazy `Enumerable` of `BillionSend.InboxStreamEvent` and
  `BillionSend.StreamGapEvent` structs. When the server ends the stream (it does
  so every few minutes) or the connection drops, it reconnects with
  Last-Event-ID set to the last id it saw and resumes without losing events,
  waiting a second (or the server's retry field) first. After `max_reconnects:`
  disconnects in a row without an event in between, the enumeration raises
  `BillionSend.APIConnectionError`; a reconnect the API refuses for good (a
  revoked key) raises its own error.

  The server replays at most 24 hours of missed events. A stream resumed from
  an older id first gets a `BillionSend.StreamGapEvent`: events may be missing,
  so read the REST lists to catch up. It is handed out once per position,
  although the server repeats it on every reconnect until a newer event arrives.

  The stream of one inbox ends after that inbox's inbox.deleted or
  inbox.expired event. Enumerate the stream once, in the process that opened
  it; halting the enumeration (`Enum.take/2`, `Stream.take_while/2`…) closes
  the connection.
  """

  alias BillionSend.{InboxStreamEvent, SSEDecoder, StreamGapEvent}

  @default_retry_ms 1_000
  @team_stream_path "/inboxes/events"
  # After one of these, the server ends an inbox's own stream for good.
  @inbox_gone ~w(inbox.deleted inbox.expired)

  @doc false
  def open(client, path, query, opts) do
    max_reconnects = Keyword.get(opts, :max_reconnects, 5)

    unless is_integer(max_reconnects) and max_reconnects >= 0,
      do: raise(ArgumentError, "max_reconnects must be 0 or more")

    state = %{
      client: client,
      path: path,
      query: query,
      last_event_id: Keyword.get(opts, :last_event_id),
      max_reconnects: max_reconnects,
      extra_headers: Keyword.get(opts, :extra_headers, []),
      timeout: Keyword.get(opts, :timeout),
      retry_ms: @default_retry_ms,
      closed: false,
      one_inbox: String.trim_trailing(path, "/") != @team_stream_path,
      # The position a gap was last handed out at; the server repeats it on reconnect.
      gap_at: :none,
      failures: 0,
      handle: nil,
      decoder: SSEDecoder.new()
    }

    with {:ok, handle} <- connect(state) do
      first = %{state | handle: handle}
      {:ok, Stream.resource(fn -> first end, &next/1, &stop/1)}
    end
  end

  defp connect(s) do
    BillionSend.Client.open_stream(
      s.client,
      s.path,
      s.query,
      s.last_event_id,
      s.extra_headers,
      s.timeout
    )
  end

  defp next(%{closed: true} = s), do: {:halt, s}

  # Disconnected: count it, wait, connect again. `failures` counts the
  # disconnects since the last event; any event starts it again.
  defp next(%{handle: nil} = s) do
    failures = s.failures + 1

    if failures > s.max_reconnects do
      raise BillionSend.APIConnectionError,
        message: "The event stream disconnected; gave up after #{s.max_reconnects} reconnects"
    end

    s.client.sleep.(s.retry_ms)

    case connect(s) do
      {:ok, handle} ->
        {[], %{s | handle: handle, decoder: SSEDecoder.new(), failures: failures}}

      {:error, error} ->
        if retryable?(error), do: {[], %{s | failures: failures}}, else: raise(error)
    end
  end

  defp next(s) do
    {module, state} = s.client.transport

    case module.next_chunk(state, s.handle) do
      {:ok, chunk, handle} ->
        {events, decoder} = SSEDecoder.feed(s.decoder, chunk)

        s = %{
          s
          | handle: handle,
            decoder: decoder,
            failures: if(events == [], do: s.failures, else: 0)
        }

        {out, s} = Enum.reduce(events, {[], s}, &saw/2)
        s = if s.closed, do: release(s), else: s
        {Enum.reverse(out), s}

      :done ->
        # Every event was handed out; an id sent without data still moves the position.
        s = %{s | last_event_id: s.decoder.last_event_id || s.last_event_id}
        {[], release(absorb_retry(s))}

      {:error, _dropped} ->
        {[], release(absorb_retry(s))}
    end
  end

  defp retryable?(%module{}),
    do:
      module in [
        BillionSend.APIConnectionError,
        BillionSend.APITimeoutError,
        BillionSend.RateLimitError,
        BillionSend.APIError
      ]

  defp saw(_sse, {out, %{closed: true} = s}), do: {out, s}

  defp saw(%{event: "stream.gap", data: data}, {out, s}) do
    if s.gap_at == {s.last_event_id} do
      {out, s}
    else
      reason =
        case data do
          %{"reason" => reason} when is_binary(reason) -> reason
          _ -> "unknown"
        end

      {[%StreamGapEvent{data: %{"reason" => reason}} | out], %{s | gap_at: {s.last_event_id}}}
    end
  end

  defp saw(%{id: id, event: event, data: %{} = data}, {out, s}) when is_binary(id) do
    closed = s.one_inbox and event in @inbox_gone

    {[%InboxStreamEvent{id: id, event: event, data: data} | out],
     %{s | last_event_id: id, closed: closed}}
  end

  defp saw(%{event: event}, _),
    do: raise(BillionSend.Error, message: "Malformed #{inspect(event)} event in the stream")

  defp absorb_retry(%{decoder: %{retry_ms: ms}} = s) when is_integer(ms), do: %{s | retry_ms: ms}
  defp absorb_retry(s), do: s

  defp release(%{handle: nil} = s), do: s

  defp release(s) do
    {module, state} = s.client.transport
    module.close_stream(state, s.handle)
    %{s | handle: nil}
  end

  defp stop(s), do: release(s)
end
