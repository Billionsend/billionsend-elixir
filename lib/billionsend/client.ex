defmodule BillionSend.Client do
  @moduledoc """
  A BillionSend API client: the key, the base URL and how requests are sent.

      client = BillionSend.client()  # reads BILLIONSEND_API_KEY
      {:ok, email} = BillionSend.Emails.send(client, %{from: "Acme <hello@acme.dev>", ...})

  It is a plain struct: build it once and pass it to every call, from any process.
  """

  alias BillionSend.{Errors, Request, Response}

  @default_base_url "https://api.billionsend.com"
  @default_timeout 60_000
  @default_max_retries 2
  # A Retry-After longer than this is not waited out: the error is returned at once.
  @max_retry_delay 60.0
  # A retry of a keyed request can meet the first attempt still running on the server.
  @concurrent_idempotent "concurrent_idempotent_requests"
  @idempotent_methods ~w(GET HEAD OPTIONS PUT DELETE)

  defstruct api_key: nil,
            base_url: @default_base_url,
            timeout: @default_timeout,
            max_retries: @default_max_retries,
            default_headers: [],
            transport: {BillionSend.Transport.Httpc, nil},
            sleep: &Process.sleep/1

  @type t :: %__MODULE__{
          api_key: String.t() | nil,
          base_url: String.t(),
          timeout: pos_integer(),
          max_retries: non_neg_integer(),
          default_headers: [{String.t(), String.t()}],
          transport: {module(), term()},
          sleep: (non_neg_integer() -> any())
        }

  @doc """
  Builds a client.

  Options:

    * `:api_key` - defaults to `BILLIONSEND_API_KEY`
    * `:base_url` - defaults to `BILLIONSEND_BASE_URL`, else `#{@default_base_url}`
    * `:timeout` - milliseconds per attempt (default #{@default_timeout}; an event
      stream waits at least 60 s for each read)
    * `:max_retries` - retries after the first attempt (default #{@default_max_retries})
    * `:default_headers` - headers sent with every request
    * `:transport` - the HTTP layer as `{module, state}` or a module
      (`BillionSend.Transport.Httpc` by default)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)

    unless is_integer(max_retries) and max_retries >= 0 do
      raise ArgumentError, "max_retries must be 0 or more"
    end

    timeout = check_timeout!(Keyword.get(opts, :timeout, @default_timeout))

    base_url =
      case Keyword.get(opts, :base_url) || System.get_env("BILLIONSEND_BASE_URL") do
        nil -> @default_base_url
        "" -> @default_base_url
        url -> String.trim_trailing(url, "/")
      end

    transport =
      case Keyword.get(opts, :transport, BillionSend.Transport.Httpc) do
        {module, state} -> {module, state}
        module when is_atom(module) -> {module, nil}
      end

    %__MODULE__{
      api_key: api_key(Keyword.get(opts, :api_key)),
      base_url: base_url,
      timeout: timeout,
      max_retries: max_retries,
      default_headers: Enum.map(Keyword.get(opts, :default_headers, []), &string_pair/1),
      transport: transport,
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1)
    }
  end

  # A key read from a file or an environment variable often ends in a newline;
  # a blank one is no key, and the environment's is tried.
  defp api_key(given) do
    case {clean_key(given), clean_key(System.get_env("BILLIONSEND_API_KEY"))} do
      {key, env} when key in [nil, ""] -> env
      {key, _} -> key
    end
  end

  defp clean_key(key) when is_binary(key), do: String.trim(key)
  defp clean_key(key), do: key

  defp check_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp check_timeout!(timeout) do
    raise ArgumentError,
          "timeout must be a positive number of milliseconds, got #{inspect(timeout)}"
  end

  defimpl Inspect do
    def inspect(client, _opts), do: "#BillionSend.Client<#{client.base_url}>"
  end

  @doc """
  Sends one request with retries; returns `{:ok, answer}` (the parsed JSON, maps
  with string keys) or `{:error, error}`. The generated resource functions call
  it; use it for anything they do not cover.

  Options: `:query` (a keyword list or map; lists are sent comma-separated),
  `:headers`, `:body` (encoded as JSON), `:multipart` (a form, in place of
  `:body`; see `BillionSend.Multipart`), `:idempotency_key`, `:auto_idempotency_key` (make one up when none is given),
  `:auth` (default true), `:extra_headers`, `:timeout`.
  """
  @spec request(t(), String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, Errors.t()}
  def request(%__MODULE__{} = client, method, path, opts \\ []) do
    {body, content_type} = encode_body(opts)

    with {:ok, headers} <-
           headers(client,
             auth: Keyword.get(opts, :auth, true),
             body: body != nil,
             content_type: content_type,
             idempotency_key: Keyword.get(opts, :idempotency_key),
             headers: Keyword.get(opts, :headers, []),
             extra_headers: Keyword.get(opts, :extra_headers, [])
           ) do
      keyed? = Enum.any?(headers, fn {k, _} -> String.downcase(k) == "idempotency-key" end)

      {headers, keyed?} =
        if Keyword.get(opts, :auto_idempotency_key, false) and not keyed? do
          {headers ++ [{"Idempotency-Key", uuid4()}], true}
        else
          {headers, keyed?}
        end

      req = %Request{
        method: method,
        url: url(client, path, Keyword.get(opts, :query)),
        headers: headers,
        body: body,
        timeout: call_timeout!(client, Keyword.get(opts, :timeout))
      }

      attempt(client, req, keyed?, 0)
    end
  end

  defp call_timeout!(client, nil), do: client.timeout
  defp call_timeout!(_client, timeout), do: check_timeout!(timeout)

  # `:body` is sent as JSON, `:multipart` as a multipart form (see `BillionSend.Multipart`).
  defp encode_body(opts) do
    case {Keyword.get(opts, :body), Keyword.get(opts, :multipart)} do
      {nil, nil} ->
        {nil, nil}

      {body, nil} ->
        {JSON.encode!(objects(body)), "application/json"}

      {nil, fields} ->
        {content_type, body} = BillionSend.Multipart.encode(fields)
        {body, content_type}
    end
  end

  # A keyword list is how an Elixir caller writes an object: send it as one, at any depth.
  defp objects(list) when is_list(list) and list != [] do
    if Keyword.keyword?(list),
      do: Map.new(list, fn {k, v} -> {k, objects(v)} end),
      else: Enum.map(list, &objects/1)
  end

  defp objects(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, objects(v)} end)

  defp objects(other), do: other

  defp attempt(client, req, keyed?, n) do
    {module, state} = client.transport

    result =
      case module.request(state, req) do
        {:ok, %Response{status: status} = response} when status in 200..299 -> parse_json(response)
        {:ok, response} -> {:error, error_from(response)}
        {:error, error} -> {:error, error}
      end

    with {:error, error} <- result do
      case retry_delay(client, n, error, req.method, keyed?) do
        nil ->
          {:error, error}

        seconds ->
          client.sleep.(round(seconds * 1000))
          attempt(client, req, keyed?, n + 1)
      end
    end
  end

  @doc false
  # The longest Retry-After waited for, in seconds; a longer one returns the error.
  def max_retry_delay, do: @max_retry_delay

  @doc false
  # Seconds to wait before retrying after `error`, or nil to return it.
  #
  # Retried: requests that are safe to repeat (GET, PUT, DELETE, or any request
  # with an idempotency key) failing with 429, 5xx or no answer at all, and a
  # keyed request whose first attempt is still running (409
  # concurrent_idempotent_requests).
  def retry_delay(client, n, error, method, keyed?) do
    cond do
      n >= client.max_retries -> nil
      method not in @idempotent_methods and not keyed? -> nil
      not retryable?(error, keyed?) -> nil
      true -> hinted_or_backoff(error, n)
    end
  end

  defp retryable?(%module{}, _)
       when module in [BillionSend.APIConnectionError, BillionSend.APITimeoutError],
       do: true

  defp retryable?(%{status_code: 409, name: name}, keyed?),
    do: keyed? and name == @concurrent_idempotent

  defp retryable?(%{status_code: 429}, _), do: true
  defp retryable?(%{status_code: status}, _) when is_integer(status) and status >= 500, do: true
  defp retryable?(_, _), do: false

  defp hinted_or_backoff(%{response: %Response{} = response}, n) do
    case retry_after(response) do
      nil -> backoff(n)
      hinted when hinted <= @max_retry_delay -> hinted
      _ -> nil
    end
  end

  defp hinted_or_backoff(_, n), do: backoff(n)

  defp backoff(n), do: min(0.5 * :math.pow(2, n), 8.0) * (1 - 0.25 * :rand.uniform())

  @doc false
  def open_stream(client, path, query, last_event_id, extra_headers, timeout) do
    {module, state} = client.transport

    with {:ok, headers} <-
           headers(client,
             auth: true,
             body: false,
             accept: "text/event-stream",
             headers: [{"Last-Event-ID", last_event_id}],
             extra_headers: extra_headers
           ) do
      req = %Request{
        method: "GET",
        url: url(client, path, query),
        headers: headers,
        timeout: call_timeout!(client, timeout)
      }

      case module.open_stream(state, req) do
        {:ok, %Response{status: status}, handle} when status in 200..299 ->
          {:ok, handle}

        {:ok, response, handle} ->
          body = (response.body || "") <> read_all(module, state, handle, "")
          module.close_stream(state, handle)
          {:error, error_from(%{response | body: body})}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp read_all(module, state, handle, acc) do
    case module.next_chunk(state, handle) do
      {:ok, chunk, handle} -> read_all(module, state, handle, acc <> chunk)
      _ -> acc
    end
  end

  @doc """
  Encodes one path segment (an id, or an inbox address such as support@example.com).
  `nil` and an empty string raise `ArgumentError`: left empty, the call would go to the
  route of the whole collection.
  """
  def encode_path(value) do
    case to_string(value) do
      "" -> raise ArgumentError, "a path parameter must not be empty (got #{inspect(value)})"
      text -> URI.encode(text, fn c -> URI.char_unreserved?(c) or c == ?@ end)
    end
  end

  @doc "Drops unset values, writes booleans as true/false and lists comma-separated in one key."
  def encode_query(query) do
    query
    |> Enum.reject(fn {_, v} -> v == nil end)
    |> Enum.map(fn
      {k, v} when is_list(v) -> {to_string(k), Enum.map_join(v, ",", &query_text/1)}
      {k, v} -> {to_string(k), query_text(v)}
    end)
    |> URI.encode_query(:rfc3986)
  end

  defp query_text(true), do: "true"
  defp query_text(false), do: "false"
  defp query_text(v), do: to_string(v)

  @doc "Seconds a Retry-After header asks for, or nil."
  def retry_after(%Response{} = response) do
    case Response.header(response, "retry-after") do
      nil ->
        nil

      header ->
        header = String.trim(header)

        case Float.parse(header) do
          {seconds, ""} ->
            max(seconds, 0.0)

          _ ->
            case http_date(header) do
              nil -> nil
              at -> max(DateTime.diff(at, DateTime.utc_now(), :millisecond) / 1000, 0.0)
            end
        end
    end
  end

  defp http_date(text) do
    case :httpd_util.convert_request_date(String.to_charlist(text)) do
      {{_, _, _}, {_, _, _}} = erl ->
        erl |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc "Maps an error answer to the matching error, keeping the API's error shape."
  def error_from(%Response{status: status, body: body} = response) do
    {name, message} =
      case JSON.decode(body || "") do
        {:ok, %{} = map} ->
          {if(is_binary(map["name"]), do: map["name"], else: "application_error"),
           if(is_binary(map["message"]), do: map["message"], else: "HTTP #{status}")}

        _ ->
          text = String.trim(body || "")

          {"application_error",
           if(text == "", do: "HTTP #{status}", else: String.slice(text, 0, 500))}
      end

    module = Errors.module_for(status)

    struct(module,
      message: message,
      name: name,
      status_code: status,
      response: response,
      request_id: Response.header(response, "x-request-id"),
      retry_after: if(module == BillionSend.RateLimitError, do: retry_after(response))
    )
  end

  defp parse_json(%Response{body: body}) when body in [nil, ""], do: {:ok, nil}

  defp parse_json(%Response{body: body} = response) do
    case JSON.decode(body) do
      {:ok, value} ->
        {:ok, value}

      {:error, _} ->
        type = Response.header(response, "content-type") || "no content type"

        {:error,
         %BillionSend.Error{
           message: "Expected a JSON answer, got #{type}",
           status_code: response.status,
           response: response,
           request_id: Response.header(response, "x-request-id")
         }}
    end
  end

  defp url(client, path, query) do
    case encode_query(query || []) do
      "" -> client.base_url <> path
      encoded -> "#{client.base_url}#{path}?#{encoded}"
    end
  end

  defp headers(client, opts) do
    out = [
      {"Accept", Keyword.get(opts, :accept, "application/json")},
      {"User-Agent", "billionsend-elixir/#{BillionSend.version()}"}
    ]

    auth =
      cond do
        not Keyword.fetch!(opts, :auth) -> {:ok, []}
        client.api_key in [nil, ""] -> :missing
        true -> {:ok, [{"Authorization", "Bearer #{client.api_key}"}]}
      end

    case auth do
      :missing ->
        {:error,
         %BillionSend.AuthenticationError{
           message: "No API key: pass api_key: or set BILLIONSEND_API_KEY",
           name: "missing_api_key"
         }}

      {:ok, auth} ->
        out = out ++ auth

        out =
          if Keyword.fetch!(opts, :body),
            do: out ++ [{"Content-Type", Keyword.get(opts, :content_type, "application/json")}],
            else: out

        out =
          case Keyword.get(opts, :idempotency_key) do
            nil -> out
            key -> out ++ [{"Idempotency-Key", key}]
          end

        out =
          out
          |> merge(client.default_headers)
          |> merge(Enum.reject(Keyword.get(opts, :headers, []), fn {_, v} -> v == nil end))
          |> merge(Keyword.get(opts, :extra_headers) || [])

        Enum.each(out, &check_header!/1)
        {:ok, out}
    end
  end

  # Sets headers, replacing any already there under another spelling of the name.
  defp merge(headers, more) do
    Enum.reduce(more, headers, fn pair, acc ->
      {name, value} = string_pair(pair)
      down = String.downcase(name)
      Enum.reject(acc, fn {k, _} -> String.downcase(k) == down end) ++ [{name, value}]
    end)
  end

  defp string_pair({k, v}), do: {to_string(k), to_string(v)}

  # A header goes on the wire as it is: a line break would end it early (header
  # injection) and a character outside printable ASCII is refused by the HTTP
  # client with an error that looks like a network failure.
  defp check_header!({name, value}) do
    unless name =~ ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/ do
      raise ArgumentError, "invalid header name #{inspect(name)}"
    end

    unless value =~ ~r/\A[\t\x20-\x7E]*\z/ do
      raise ArgumentError,
            "the value of header #{name} must be printable ASCII without line breaks " <>
              "(an API key and an idempotency key included)"
    end

    :ok
  end

  @doc false
  def uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
  end

  # --- the generated functions' plumbing -------------------------------------------------

  @doc false
  # Runs one operation for a generated function: checks `opts` against the
  # operation's parameters, then sends the request.
  def call(client, method, path, opts, spec) do
    query = Keyword.get(spec, :query, [])
    header_params = Keyword.get(spec, :headers, [])
    allowed = Enum.map(query ++ header_params, &elem(&1, 1)) ++ Keyword.get(spec, :extra, [])
    check_opts!(opts, allowed ++ [:extra_headers, :timeout], Keyword.get(spec, :required, []))

    request(client, method, path,
      query: Enum.map(query, fn {name, key} -> {name, Keyword.get(opts, key)} end),
      headers: Enum.map(header_params, fn {name, key} -> {name, Keyword.get(opts, key)} end),
      body: Keyword.get(spec, :body),
      multipart: Keyword.get(spec, :multipart),
      idempotency_key: Keyword.get(opts, :idempotency_key),
      auto_idempotency_key: Keyword.has_key?(spec, :idempotent),
      auth: Keyword.get(spec, :auth, true),
      extra_headers: Keyword.get(opts, :extra_headers, []),
      timeout: Keyword.get(opts, :timeout)
    )
  end

  @doc false
  def check_opts!(opts, allowed, required) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "options must be a keyword list")

    case Keyword.keys(opts) -- allowed do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "unknown options #{inspect(unknown)}; known: #{inspect(allowed)}"
    end

    case Enum.reject(required, &Keyword.has_key?(opts, &1)) do
      [] -> :ok
      missing -> raise ArgumentError, "missing required options #{inspect(missing)}"
    end
  end

  @doc false
  # The body and options of a call whose body may be left out: a keyword list
  # in the body's place is the options; an unset body is {} unless the
  # operation takes none at all (`omit?`).
  def optional_body(params, opts, omit?) do
    {params, opts} =
      if opts == [] and is_list(params) and params != [] and Keyword.keyword?(params),
        do: {nil, params},
        else: {params, opts}

    {if(params == nil and not omit?, do: %{}, else: params), opts}
  end

  @doc false
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, error}), do: raise(error)
end
