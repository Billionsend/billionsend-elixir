defmodule BillionSend.SSEDecoderTest do
  use ExUnit.Case, async: true
  alias BillionSend.SSEDecoder

  test "parses events split anywhere and any line ending" do
    text =
      "﻿: keepalive\r\nid: 1\r\nevent: inbox.email.received\r\ndata: {\"a\":\r\n\r\n" <>
        "id: 2\nevent: x\ndata: line one\ndata: line two\n\n" <>
        "id: 3\revent: y\rdata: {\"é\": 1}\r\r"

    chunks = for <<chunk::binary-size(3) <- text>>, do: chunk
    rest = binary_part(text, length(chunks) * 3, byte_size(text) - length(chunks) * 3)

    {events, _} =
      Enum.reduce(chunks ++ [rest], {[], SSEDecoder.new()}, fn chunk, {acc, d} ->
        {events, d} = SSEDecoder.feed(d, chunk)
        {acc ++ events, d}
      end)

    assert Enum.map(events, & &1.id) == ~w(1 2 3)
    assert Enum.map(events, & &1.event) == ~w(inbox.email.received x y)
    assert Enum.at(events, 0).data == "{\"a\":"
    assert Enum.at(events, 1).data == "line one\nline two"
    assert Enum.at(events, 2).data == %{"é" => 1}
  end

  test "retry and the default event name" do
    {[event], d} = SSEDecoder.feed(SSEDecoder.new(), "retry: 2500\ndata: {}\n\n")
    assert d.retry_ms == 2500
    assert event.event == "message"
  end

  defp feed_all(chunks) do
    Enum.reduce(chunks, {[], SSEDecoder.new()}, fn chunk, {acc, d} ->
      {events, d} = SSEDecoder.feed(d, chunk)
      {acc ++ events, d}
    end)
  end

  test "a CRLF split between two chunks is one line ending" do
    {events, _} = feed_all(["id: 1\r", "\ndata: {}\r", "\n\r", "\n"])
    assert [%{id: "1", data: %{}}] = events
  end

  test "an id carries over to the events after it, and a NUL in an id ignores it" do
    {events, d} = feed_all(["id: a\ndata: 1\n\ndata: 2\n\nid: b\0c\ndata: 3\n\n"])
    assert Enum.map(events, & &1.id) == ["a", "a", "a"]
    assert d.last_event_id == "a"
  end

  test "an id with no data moves the position without making an event" do
    {events, d} = feed_all(["id: 9\n\n"])
    assert events == []
    assert d.last_event_id == "9"
  end

  test "the event name is for one event only, a retry that is not a number is ignored" do
    {events, d} = feed_all(["event: a\ndata: 1\n\ndata: 2\n\nretry: soon\nretry: 1x\n"])
    assert Enum.map(events, & &1.event) == ["a", "message"]
    assert d.retry_ms == nil
  end

  test "comments, unknown fields and a missing colon are skipped or empty" do
    {events, _} = feed_all([": hi\nunknown: x\ndata\ndata:  two spaces\n\n"])
    assert [%{data: data}] = events
    # `data` alone is an empty line, and only one leading space of a value is dropped.
    assert data == "\n two spaces"
  end

  test "data that is not JSON stays text, empty data is an empty text" do
    {events, _} = feed_all(["data: not json\n\ndata:\n\n"])
    assert Enum.map(events, & &1.data) == ["not json", ""]
  end

  test "a byte order mark is dropped from the start of the stream only" do
    {events, _} = feed_all(["\uFEFFid: 1\ndata: {}\n\n", "\uFEFFid: 2\ndata: {}\n\n"])
    # The second mark is part of a field name, so its id line is not an id line.
    assert Enum.map(events, & &1.id) == ["1", "1"]
  end
end

defmodule BillionSend.EventStreamTest do
  use ExUnit.Case, async: true

  import BillionSend.Test.Helpers
  alias BillionSend.{InboxStreamEvent, StreamGapEvent}
  alias BillionSend.Test.Mock
  alias BillionSend.Test.Mock.Call

  @team "/inboxes/events"
  @inbox "/inboxes/{inbox_id}/events"

  defp frame(id, event) do
    data = %{
      "type" => event,
      "created_at" => "2026-11-17T00:00:00.000Z",
      "inbox_id" => "ib_1",
      "data" => %{}
    }

    "id: #{id}\nevent: #{event}\ndata: #{JSON.encode!(data)}\n\n"
  end

  defp answer(mock, path, chunks, error \\ nil) do
    Mock.respond(mock, "GET", path, 200,
      headers: [{"content-type", "text/event-stream"}],
      chunks: chunks,
      error: error
    )
  end

  test "reconnects with the last event id and resumes" do
    {client, mock} = client()
    answer(mock, @team, [frame("1", "inbox.email.received"), frame("2", "inbox.thread.created")])

    answer(
      mock,
      @team,
      ["retry: 250\n", frame("3", "inbox.email.received")],
      %BillionSend.APIConnectionError{message: "reset"}
    )

    answer(mock, @team, [frame("4", "inbox.email.received")])

    {:ok, stream} =
      BillionSend.Inboxes.Events.stream(client,
        types: ~w(inbox.email.received inbox.thread.created)
      )

    got = Enum.take(stream, 4)

    assert Enum.map(got, & &1.id) == ~w(1 2 3 4)
    assert Enum.all?(got, &match?(%InboxStreamEvent{}, &1))
    assert Enum.map(Mock.calls(mock), &Call.header(&1, "last-event-id")) == [nil, "2", "3"]
    assert hd(Mock.calls(mock)).query["types"] == ["inbox.email.received,inbox.thread.created"]
    assert sleeps() == [1000, 250]
    assert Mock.streams_closed?(mock)
  end

  test "a gap is handed out once per position" do
    {client, mock} = client()
    gap = "event: stream.gap\ndata: {\"reason\":\"retention\"}\n\n"
    answer(mock, @team, [gap])
    answer(mock, @team, [gap, frame("9", "inbox.email.received")])
    {:ok, stream} = BillionSend.Inboxes.Events.stream(client, last_event_id: "old")
    [first, second] = Enum.take(stream, 2)
    assert %StreamGapEvent{event: "stream.gap", id: nil, data: %{"reason" => "retention"}} = first
    assert second.id == "9"
    assert Call.header(hd(Mock.calls(mock)), "last-event-id") == "old"
  end

  test "an inbox stream ends after the inbox is deleted" do
    {client, mock} = client()
    answer(mock, @inbox, [frame("1", "inbox.email.received"), frame("2", "inbox.deleted")])
    {:ok, stream} = BillionSend.Inboxes.Events.stream_inbox(client, "support@example.com")
    assert Enum.map(stream, & &1.event) == ~w(inbox.email.received inbox.deleted)
    assert length(Mock.calls(mock)) == 1
  end

  test "a refused stream is an error when opened" do
    {client, mock} = client()
    Mock.error(mock, "GET", @team, 403, "forbidden", "Needs a team-wide key")

    assert {:error, %BillionSend.PermissionDeniedError{}} =
             BillionSend.Inboxes.Events.stream(client)

    assert_raise BillionSend.PermissionDeniedError, fn ->
      Mock.error(mock, "GET", @team, 403, "forbidden", "Needs a team-wide key")
      BillionSend.Inboxes.Events.stream!(client)
    end
  end

  test "reconnect failures are bounded" do
    {client, mock} = client()
    answer(mock, @team, [frame("1", "inbox.email.received")])
    for _ <- 1..3, do: Mock.error(mock, "GET", @team, 503, "unavailable", "Try later")
    {:ok, stream} = BillionSend.Inboxes.Events.stream(client, max_reconnects: 2)

    assert_raise BillionSend.APIError, "503 unavailable: Try later", fn -> Enum.to_list(stream) end
    assert sleeps() == [1000, 1000]
  end

  test "a quiet inbox keeps reconnecting" do
    {client, mock} = client()
    # The server ends a stream every ten minutes; a quiet inbox gets only keepalives.
    for _ <- 1..8, do: answer(mock, @team, [": keepalive\n\n"])
    answer(mock, @team, [frame("1", "inbox.email.received")])
    {:ok, stream} = BillionSend.Inboxes.Events.stream(client, max_reconnects: 1)
    assert Enum.map(Enum.take(stream, 1), & &1.id) == ~w(1)
    assert length(Mock.calls(mock)) == 9
    assert sleeps() == List.duplicate(1000, 8)
  end

  test "a connection that opens starts the count again" do
    {client, mock} = client()
    # Without the reset, the 3rd failed reconnect would pass max_reconnects 2.
    answer(mock, @team, [])

    for _ <- 1..2 do
      Mock.error(mock, "GET", @team, 503, "unavailable", "Try later")
      answer(mock, @team, [])
    end

    Mock.error(mock, "GET", @team, 503, "unavailable", "Try later")
    answer(mock, @team, [frame("1", "inbox.email.received")])
    {:ok, stream} = BillionSend.Inboxes.Events.stream(client, max_reconnects: 2)
    assert Enum.map(Enum.take(stream, 1), & &1.id) == ~w(1)
  end

  test "an error raised while handling an event passes through" do
    {client, mock} = client()
    answer(mock, @team, [frame("1", "inbox.email.received"), frame("2", "inbox.email.received")])
    {:ok, stream} = BillionSend.Inboxes.Events.stream(client)

    assert_raise BillionSend.APIConnectionError, "application_error: the reply failed", fn ->
      Enum.each(stream, fn _ ->
        raise BillionSend.APIConnectionError, message: "the reply failed"
      end)
    end

    assert length(Mock.calls(mock)) == 1
  end

  test "a refused reconnect waits its Retry-After and raises the API's error" do
    {client, mock} = client()
    answer(mock, @team, [frame("1", "inbox.email.received")])

    for _ <- 1..3,
        do:
          Mock.error(mock, "GET", @team, 429, "too_many_streams", "Too many open streams",
            headers: [{"retry-after", "5"}]
          )

    {:ok, stream} = BillionSend.Inboxes.Events.stream(client, max_reconnects: 2)
    error = assert_raise BillionSend.RateLimitError, fn -> Enum.to_list(stream) end
    assert error.name == "too_many_streams"
    assert sleeps() == [1000, 5000]
  end

  test "a Retry-After over a minute raises at once" do
    {client, mock} = client()
    answer(mock, @team, [frame("1", "inbox.email.received")])

    Mock.error(mock, "GET", @team, 503, "unavailable", "Down for maintenance",
      headers: [{"retry-after", "120"}]
    )

    {:ok, stream} = BillionSend.Inboxes.Events.stream(client)
    assert_raise BillionSend.APIError, fn -> Enum.to_list(stream) end
    assert sleeps() == [1000]
    assert length(Mock.calls(mock)) == 2
  end

  test "reconnects that get no answer raise a connection error" do
    {client, mock} = client()
    answer(mock, @team, [frame("1", "inbox.email.received")])

    Mock.error(mock, "GET", @team, 429, "too_many_streams", "Too many open streams",
      headers: [{"retry-after", "2"}]
    )

    for _ <- 1..2,
        do:
          Mock.fail(mock, "GET", @team, %BillionSend.APIConnectionError{
            message: "Connection refused"
          })

    {:ok, stream} = BillionSend.Inboxes.Events.stream(client, max_reconnects: 2)

    assert_raise BillionSend.APIConnectionError,
                 "application_error: The event stream disconnected; gave up after 2 reconnects",
                 fn -> Enum.to_list(stream) end

    assert sleeps() == [1000, 2000]
  end

  test "a refused reconnect raises its own error" do
    {client, mock} = client()
    answer(mock, @team, [frame("1", "inbox.email.received")])
    Mock.error(mock, "GET", @team, 401, "invalid_api_key", "Revoked")
    {:ok, stream} = BillionSend.Inboxes.Events.stream(client)
    assert_raise BillionSend.AuthenticationError, fn -> Enum.to_list(stream) end
  end

  test "without reconnects a dropped connection raises" do
    {client, mock} = client()

    answer(mock, @team, [frame("1", "inbox.email.received")], %BillionSend.APIConnectionError{
      message: "reset"
    })

    {:ok, stream} = BillionSend.Inboxes.Events.stream(client, max_reconnects: 0)

    assert_raise BillionSend.APIConnectionError, fn ->
      Enum.each(stream, fn _ -> send(self(), :event) end)
    end

    assert_received :event
  end

  defp saw_event(id), do: frame(id, "inbox.email.received")

  test "a position sent alone is where a dropped connection resumes from" do
    {client, mock} = client()
    answer(mock, @team, ["id: 5\n\n"], %BillionSend.APIConnectionError{message: "reset"})
    answer(mock, @team, [frame("6", "inbox.email.received")])
    {:ok, stream} = BillionSend.Inboxes.Events.stream(client)
    assert [%{id: "6"}] = Enum.take(stream, 1)
    assert Enum.map(Mock.calls(mock), &Call.header(&1, "last-event-id")) == [nil, "5"]
  end

  test "a position sent alone is where a connection that ends cleanly resumes from, too" do
    {client, mock} = client()
    answer(mock, @team, ["retry: 400\nid: 5\n\n"])
    answer(mock, @team, [frame("6", "inbox.email.received")])
    {:ok, stream} = BillionSend.Inboxes.Events.stream(client)
    assert [%{id: "6"}] = Enum.take(stream, 1)
    assert Enum.map(Mock.calls(mock), &Call.header(&1, "last-event-id")) == [nil, "5"]
    assert sleeps() == [400]
  end

  test "a retry the server asked for before a drop is the wait before reconnecting" do
    {client, mock} = client()
    answer(mock, @team, ["retry: 700\n\n"], %BillionSend.APIConnectionError{message: "reset"})
    answer(mock, @team, [frame("1", "inbox.email.received")])
    {:ok, stream} = BillionSend.Inboxes.Events.stream(client)
    assert [%{id: "1"}] = Enum.take(stream, 1)
    assert sleeps() == [700]
  end

  test "an event that is not what the stream carries raises instead of being skipped" do
    for chunk <- [
          "id: 1\nevent: inbox.email.received\ndata: [1]\n\n",
          "id: 1\nevent: inbox.email.received\ndata: text\n\n",
          "event: inbox.email.received\ndata: {}\n\n"
        ] do
      {client, mock} = client()
      answer(mock, @team, [chunk])
      {:ok, stream} = BillionSend.Inboxes.Events.stream(client)
      error = assert_raise BillionSend.Error, fn -> Enum.to_list(stream) end
      assert error.message =~ "Malformed"
    end
  end

  test "a gap with no reason says so, and a gap at a new position is handed out again" do
    {client, mock} = client()
    gap = "event: stream.gap\ndata: {}\n\n"
    answer(mock, @team, [gap, frame("1", "inbox.email.received")])
    answer(mock, @team, [gap, frame("2", "inbox.email.received")])
    {:ok, stream} = BillionSend.Inboxes.Events.stream(client)
    got = Enum.take(stream, 4)

    assert [
             %StreamGapEvent{data: %{"reason" => "unknown"}},
             %{id: "1"},
             %StreamGapEvent{},
             %{id: "2"}
           ] = got
  end

  test "the team's stream goes on after an inbox is deleted, one inbox's ends and ignores what follows" do
    {client, mock} = client()
    answer(mock, @team, [frame("1", "inbox.deleted"), frame("2", "inbox.email.received")])
    {:ok, stream} = BillionSend.Inboxes.Events.stream(client)
    assert Enum.map(Enum.take(stream, 2), & &1.id) == ~w(1 2)

    {client, mock} = client()
    answer(mock, @inbox, [frame("1", "inbox.expired") <> frame("2", "inbox.email.received")])
    {:ok, stream} = BillionSend.Inboxes.Events.stream_inbox(client, "ib_1")
    assert Enum.map(stream, & &1.id) == ["1"]
    assert length(Mock.calls(mock)) == 1
    assert Mock.streams_closed?(mock)
  end

  test "reconnect settings are checked when the stream is opened" do
    {client, _} = client()

    for bad <- [-1, 1.5, "5", nil] do
      assert_raise ArgumentError, ~r/max_reconnects/, fn ->
        BillionSend.Inboxes.Events.stream(client, max_reconnects: bad)
      end
    end
  end

  test "a name or a list of names narrows the stream, the key and headers travel with it" do
    {client, mock} = client(timeout: 4_321)
    answer(mock, @team, [])
    answer(mock, @team, [])

    {:ok, _} =
      BillionSend.Inboxes.Events.stream(client,
        types: "inbox.email.received",
        extra_headers: [{"x-trace", "t"}]
      )

    {:ok, _} = BillionSend.Inboxes.Events.stream(client, types: ["a", "b"], timeout: 99)
    [one, two] = Mock.calls(mock)
    assert one.query == %{"types" => ["inbox.email.received"]}
    assert two.query == %{"types" => ["a,b"]}
    assert Call.header(one, "x-trace") == "t"
    assert Enum.map([one, two], & &1.request.timeout) == [4_321, 99]
    assert Call.header(one, "authorization") == "Bearer " <> BillionSend.Test.Contract.api_key()
  end

  test "stream! hands out the stream itself" do
    {client, mock} = client()
    answer(mock, @team, [saw_event("1")])
    assert [%{id: "1"}] = client |> BillionSend.Inboxes.Events.stream!() |> Enum.take(1)
  end
end
