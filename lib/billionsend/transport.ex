defmodule BillionSend.Request do
  @moduledoc "One HTTP request, as the client hands it to a transport. Header names are as sent."
  defstruct [:method, :url, headers: [], body: nil, timeout: 60_000]

  @type t :: %__MODULE__{
          method: String.t(),
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary() | nil,
          timeout: pos_integer()
        }
end

defmodule BillionSend.Response do
  @moduledoc "One HTTP answer. Header names are lower case."
  defstruct [:status, headers: %{}, body: ""]

  @type t :: %__MODULE__{
          status: pos_integer(),
          headers: %{String.t() => String.t()},
          body: binary()
        }

  @doc "A header's value, whatever the case of `name`."
  def header(%__MODULE__{headers: headers}, name), do: Map.get(headers, String.downcase(name))
end

defmodule BillionSend.Transport do
  @moduledoc """
  The HTTP layer. The client takes a transport as `{module, state}` (or a
  module, with `nil` state); `BillionSend.Transport.Httpc` is the default.

  `request/2` answers one request. `open_stream/2` opens an event stream and
  returns its status and headers with a handle; `next_chunk/2` reads the next
  piece of its body as soon as it arrives, with the handle to read on from
  (`:done` at the end), and `close_stream/2` lets it go. An
  answer that is not a stream may come back whole, its body in the response. A
  stream is read by the process that opened it. Failures without an answer are
  returned as `BillionSend.APIConnectionError` or `BillionSend.APITimeoutError`.
  """

  @type state :: term()
  @type handle :: term()

  @callback request(state, BillionSend.Request.t()) ::
              {:ok, BillionSend.Response.t()} | {:error, BillionSend.Errors.t()}
  @callback open_stream(state, BillionSend.Request.t()) ::
              {:ok, BillionSend.Response.t(), handle} | {:error, BillionSend.Errors.t()}
  @callback next_chunk(state, handle) ::
              {:ok, binary(), handle} | :done | {:error, BillionSend.Errors.t()}
  @callback close_stream(state, handle) :: :ok
end

defmodule BillionSend.Transport.Httpc do
  @moduledoc """
  The default transport: OTP's `:httpc` (inets) over `:ssl`, verifying the
  server's certificate against the system's CA store. No redirects are followed.
  """
  @behaviour BillionSend.Transport

  # A read that waits far longer than an event stream's 15-second keepalive
  # means the connection is gone.
  @stream_read_timeout 60_000

  alias BillionSend.{APIConnectionError, APITimeoutError, Request, Response}

  @profile :billionsend

  @impl true
  def request(_state, %Request{} = req) do
    ensure_started()

    with {:ok, http_options} <- http_options(req) do
      case :httpc.request(
             method(req),
             request_tuple(req),
             http_options,
             [body_format: :binary],
             @profile
           ) do
        {:ok, {{_, status, _}, headers, body}} ->
          {:ok, %Response{status: status, headers: headers_map(headers), body: body}}

        {:error, reason} ->
          {:error, failure(reason)}
      end
    end
  end

  @impl true
  def open_stream(_state, %Request{} = req) do
    ensure_started()

    with {:ok, ssl} <- stream_ssl(req) do
      BillionSend.Transport.SSEConnection.open(req, ssl, max(req.timeout, @stream_read_timeout))
    end
  end

  @impl true
  def next_chunk(_state, :done), do: :done
  def next_chunk(_state, conn), do: BillionSend.Transport.SSEConnection.next(conn)

  @impl true
  def close_stream(_state, conn), do: BillionSend.Transport.SSEConnection.close(conn)

  defp stream_ssl(%Request{url: url}) do
    if String.starts_with?(url, "https:") do
      with {:ok, cacerts} <- cacerts() do
        {:ok, ssl_options(url, cacerts)}
      end
    else
      {:ok, []}
    end
  end

  # The SDK's own :httpc profile, so its settings touch nothing else of the
  # application: no request ever waits in line on a connection that is still
  # busy with another one (keep-alive queueing, pipelining), since a request
  # that timed out leaves its connection open, and the next one queued behind
  # it would fail when that connection finally closes.
  defp ensure_started do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    case :inets.start(:httpc, profile: @profile) do
      {:ok, _} ->
        :ok =
          :httpc.set_options(
            [
              max_keep_alive_length: 0,
              max_pipeline_length: 0,
              max_sessions: 1_000,
              keep_alive_timeout: 0
            ],
            @profile
          )

      {:error, {:already_started, _}} ->
        :ok
    end
  end

  defp method(%Request{method: m}), do: m |> String.downcase() |> String.to_existing_atom()

  defp request_tuple(%Request{url: url, headers: headers, body: nil}) do
    {String.to_charlist(url), charlist_headers(headers)}
  end

  defp request_tuple(%Request{url: url, headers: headers, body: body}) do
    {content_type, rest} =
      Enum.split_with(headers, fn {k, _} -> String.downcase(k) == "content-type" end)

    type =
      case content_type do
        [{_, value} | _] -> value
        [] -> "application/json"
      end

    {String.to_charlist(url), charlist_headers(rest), String.to_charlist(type), body}
  end

  # One connection per request: a pooled keep-alive connection the server has
  # already closed fails a request that never reached it, which for a request
  # that cannot be retried (a POST without an idempotency key) is a lost call.
  defp charlist_headers(headers) do
    [
      {~c"connection", ~c"close"}
      | Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    ]
  end

  defp http_options(%Request{url: url, timeout: timeout}) do
    base = [timeout: timeout, connect_timeout: timeout, autoredirect: false]

    if String.starts_with?(url, "https:") do
      with {:ok, cacerts} <- cacerts() do
        ssl = ssl_options(url, cacerts)

        {:ok, [{:ssl, ssl} | base]}
      end
    else
      # Given, so that :httpc does not look up the CA store for a plain-HTTP request.
      {:ok, [{:ssl, []} | base]}
    end
  end

  defp ssl_options(url, cacerts) do
    host = url |> URI.parse() |> Map.fetch!(:host) |> String.to_charlist()

    [
      verify: :verify_peer,
      cacerts: cacerts,
      server_name_indication: host,
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp cacerts do
    {:ok, :public_key.cacerts_get()}
  rescue
    error ->
      {:error,
       %APIConnectionError{
         message: "No CA certificates to verify the API with: #{Exception.message(error)}"
       }}
  catch
    _, reason ->
      {:error,
       %APIConnectionError{message: "No CA certificates to verify the API with: #{inspect(reason)}"}}
  end

  defp headers_map(headers) do
    Map.new(headers, fn {k, v} -> {k |> to_string() |> String.downcase(), to_string(v)} end)
  end

  defp failure(:timeout), do: %APITimeoutError{message: "Request timed out"}
  defp failure({:failed_connect, _} = reason), do: connection(reason)
  defp failure(reason), do: connection(reason)

  defp connection(reason),
    do: %APIConnectionError{message: "Connection error: #{inspect(reason)}"}
end
