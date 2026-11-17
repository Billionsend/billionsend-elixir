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
  piece of its body (`:done` at the end) and `close_stream/2` lets it go. A
  stream is read by the process that opened it. Failures without an answer are
  returned as `BillionSend.APIConnectionError` or `BillionSend.APITimeoutError`.
  """

  @type state :: term()
  @type handle :: term()

  @callback request(state, BillionSend.Request.t()) ::
              {:ok, BillionSend.Response.t()} | {:error, BillionSend.Errors.t()}
  @callback open_stream(state, BillionSend.Request.t()) ::
              {:ok, BillionSend.Response.t(), handle} | {:error, BillionSend.Errors.t()}
  @callback next_chunk(state, handle) :: {:ok, binary()} | :done | {:error, BillionSend.Errors.t()}
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

  @impl true
  def request(_state, %Request{} = req) do
    ensure_started()

    with {:ok, http_options} <- http_options(req) do
      case :httpc.request(method(req), request_tuple(req), http_options, body_format: :binary) do
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
    options = [sync: false, stream: {:self, :once}, body_format: :binary]

    with {:ok, http_options} <- http_options(req) do
      case :httpc.request(method(req), request_tuple(req), http_options, options) do
        {:ok, id} -> await_head(id, req.timeout)
        {:error, reason} -> {:error, failure(reason)}
      end
    end
  end

  @impl true
  def next_chunk(_state, {id, pid, timeout}) do
    :ok = :httpc.stream_next(pid)

    receive do
      {:http, {^id, :stream, chunk}} -> {:ok, chunk}
      {:http, {^id, :stream_end, _headers}} -> :done
      {:http, {^id, {:error, reason}}} -> {:error, failure(reason)}
    after
      timeout ->
        :httpc.cancel_request(id)
        {:error, %APITimeoutError{message: "No event stream data for #{div(timeout, 1000)} s"}}
    end
  end

  def next_chunk(_state, {:body, body}), do: if(body == "", do: :done, else: {:ok, body})
  def next_chunk(_state, :done), do: :done

  @impl true
  def close_stream(_state, {id, _pid, _timeout}) do
    :httpc.cancel_request(id)
    flush(id)
  end

  def close_stream(_state, _), do: :ok

  defp await_head(id, timeout) do
    receive do
      {:http, {^id, :stream_start, headers, pid}} ->
        response = %Response{status: 200, headers: headers_map(headers)}
        {:ok, response, {id, pid, max(timeout, @stream_read_timeout)}}

      # :httpc streams only a 200 answer; any other comes back whole.
      {:http, {^id, {{_, status, _}, headers, body}}} ->
        {:ok, %Response{status: status, headers: headers_map(headers), body: body}, {:body, body}}

      {:http, {^id, {:error, reason}}} ->
        {:error, failure(reason)}
    after
      timeout ->
        :httpc.cancel_request(id)
        flush(id)
        {:error, %APITimeoutError{message: "Request timed out"}}
    end
  end

  defp flush(id) do
    receive do
      {:http, {^id, _}} -> flush(id)
      {:http, {^id, _, _}} -> flush(id)
      {:http, {^id, _, _, _}} -> flush(id)
    after
      0 -> :ok
    end
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    :ok
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

  defp charlist_headers(headers) do
    Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp http_options(%Request{url: url, timeout: timeout}) do
    base = [timeout: timeout, connect_timeout: timeout, autoredirect: false]

    if String.starts_with?(url, "https:") do
      with {:ok, cacerts} <- cacerts() do
        host = url |> URI.parse() |> Map.fetch!(:host) |> String.to_charlist()

        ssl = [
          verify: :verify_peer,
          cacerts: cacerts,
          server_name_indication: host,
          depth: 4,
          customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
        ]

        {:ok, [{:ssl, ssl} | base]}
      end
    else
      # Given, so that :httpc does not look up the CA store for a plain-HTTP request.
      {:ok, [{:ssl, []} | base]}
    end
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
