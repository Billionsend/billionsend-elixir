defmodule BillionSend.Test.Contract do
  @moduledoc """
  A contract mock of the BillionSend API built from the OpenAPI snapshot,
  standing in for the client's transport. For every request it:

  1. finds the operation (method + path template) in the snapshot, or fails;
  2. checks the API key header (absent only where the operation's security is empty);
  3. checks path, query and header parameters and validates the JSON body
     against the operation's schema ($ref resolved through the snapshot);
  4. answers with a queued answer, or else with an instance of the operation's
     success schema built from the schema itself (and validated against it).

  Every hit is recorded, so the coverage test can compare what the SDK called
  with what the snapshot declares.
  """

  @snapshot Path.expand("../../openapi/api.openapi.json", __DIR__)
  @external_resource @snapshot
  @spec_doc @snapshot |> File.read!() |> JSON.decode!()
  @methods ~w(get put post patch delete)

  def api_key, do: "bs_test_key"
  def base_url, do: "https://api.test.billionsend.com"
  def spec, do: @spec_doc

  @formats %{
    "uuid" => "0b6f5a2e-7c1d-4e8a-9f3b-2d4c6e8a0b1c",
    "date-time" => "2026-01-01T00:00:00.000Z",
    "date" => "2026-01-01",
    "email" => "user@example.com",
    "uri" => "https://example.com/"
  }

  defmodule Operation do
    @moduledoc false
    defstruct [:method, :path, :spec, :regex, :names]

    def key(op), do: {op.method, op.path}
    def id(op), do: op.spec["operationId"]
    def params(op, where), do: Enum.filter(op.spec["parameters"] || [], &(&1["in"] == where))

    def needs_auth?(op),
      do: Map.get(op.spec, "security", BillionSend.Test.Contract.spec()["security"]) != []

    def success(op) do
      {code, response} =
        op.spec["responses"]
        |> Enum.filter(fn {c, _} -> String.starts_with?(c, "2") end)
        |> Enum.min_by(&elem(&1, 0))

      case Enum.to_list(response["content"] || %{}) do
        [{media, body} | _] -> {String.to_integer(code), media, body["schema"]}
        [] -> {String.to_integer(code), "application/json", nil}
      end
    end

    def idempotency_key?(op),
      do: Enum.any?(params(op, "header"), &(String.downcase(&1["name"]) == "idempotency-key"))
  end

  @operations (for {path, item} <- @spec_doc["paths"], {m, op} <- item, m in @methods do
                 names = Regex.scan(~r/\{(\w+)\}/, path, capture: :all_but_first) |> List.flatten()
                 pattern = Regex.replace(~r/\\\{\w+\\\}/, Regex.escape(path), "([^/]+)")

                 %{
                   method: String.upcase(m),
                   path: path,
                   spec: op,
                   regex: "\\A#{pattern}\\z",
                   names: names
                 }
               end)
              |> Enum.sort_by(fn o ->
                {-Enum.count(
                   String.split(o.path, "/"),
                   &(&1 != "" and not String.contains?(&1, "{"))
                 ), o.path}
              end)

  def operations do
    Enum.map(@operations, fn o -> struct(Operation, %{o | regex: Regex.compile!(o.regex)}) end)
  end

  def operation(method, path) do
    Enum.find(operations(), &(&1.method == method and &1.path == path)) ||
      raise "#{method} #{path} is not in the contract"
  end

  def find(method, path) do
    ops = operations()

    matching =
      Enum.flat_map(ops, fn op ->
        case Regex.run(op.regex, path, capture: :all_but_first) do
          nil -> []
          values -> [{op, Map.new(Enum.zip(op.names, Enum.map(values, &URI.decode/1)))}]
        end
      end)

    case Enum.find(matching, fn {op, _} -> op.method == method end) do
      nil ->
        reason = if matching == [], do: "no such path", else: "method not allowed"
        flunk("#{method} #{path}: not an operation of the contract (#{reason})")

      found ->
        found
    end
  end

  def flunk(message), do: raise(ExUnit.AssertionError, message: message)

  def resolve(%{"$ref" => "#/" <> ref}), do: resolve(get_in(@spec_doc, String.split(ref, "/")))
  def resolve(schema), do: schema || %{}

  # --- validation: the keywords the snapshot uses --------------------------------------------

  @doc "The problems of `value` against `schema` (empty when it matches)."
  def errors(value, schema, at \\ "")

  def errors(value, %{"$ref" => _} = schema, at), do: errors(value, resolve(schema), at)

  def errors(value, schema, at) when is_map(schema) do
    checks = [
      &type_errors/3,
      &enum_errors/3,
      &any_of_errors/3,
      &one_of_errors/3,
      &all_of_errors/3,
      &string_errors/3,
      &number_errors/3,
      &array_errors/3,
      &object_errors/3
    ]

    Enum.flat_map(checks, & &1.(value, schema, at))
  end

  defp type_errors(value, %{"type" => types}, at) do
    if Enum.any?(List.wrap(types), &type?(value, &1)),
      do: [],
      else: ["#{at}: #{inspect(value)} is not #{inspect(types)}"]
  end

  defp type_errors(_, _, _), do: []

  defp type?(v, "string"), do: is_binary(v)
  defp type?(v, "integer"), do: is_integer(v) or (is_float(v) and Float.round(v) == v)
  defp type?(v, "number"), do: is_number(v)
  defp type?(v, "boolean"), do: is_boolean(v)
  defp type?(v, "null"), do: v == nil
  defp type?(v, "array"), do: is_list(v)
  defp type?(v, "object"), do: is_map(v)

  defp enum_errors(value, %{"enum" => values}, at),
    do:
      if(value in values,
        do: [],
        else: ["#{at}: #{inspect(value)} is not one of #{inspect(values)}"]
      )

  defp enum_errors(_, _, _), do: []

  defp any_of_errors(value, %{"anyOf" => variants}, at) do
    if Enum.any?(variants, &(errors(value, &1, at) == [])),
      do: [],
      else: ["#{at}: matches none of anyOf"]
  end

  defp any_of_errors(_, _, _), do: []

  defp one_of_errors(value, %{"oneOf" => variants}, at) do
    case Enum.count(variants, &(errors(value, &1, at) == [])) do
      1 -> []
      n -> ["#{at}: matches #{n} of oneOf"]
    end
  end

  defp one_of_errors(_, _, _), do: []

  defp all_of_errors(value, %{"allOf" => parts}, at),
    do: Enum.flat_map(parts, &errors(value, &1, at))

  defp all_of_errors(_, _, _), do: []

  defp string_errors(value, schema, at) when is_binary(value) do
    length = String.length(value)

    [
      if(schema["minLength"] && length < schema["minLength"],
        do: "#{at}: shorter than #{schema["minLength"]}"
      ),
      if(schema["maxLength"] && length > schema["maxLength"],
        do: "#{at}: longer than #{schema["maxLength"]}"
      ),
      if(schema["pattern"] && not Regex.match?(Regex.compile!(schema["pattern"], "u"), value),
        do: "#{at}: does not match #{schema["pattern"]}"
      ),
      format_error(value, schema["format"], at)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp string_errors(_, _, _), do: []

  defp format_error(value, "uuid", at) do
    unless value =~
             ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/,
           do: "#{at}: #{inspect(value)} is not a uuid"
  end

  defp format_error(value, "email", at) do
    unless value =~ ~r/\A[^@\s]+@[^@\s]+\z/, do: "#{at}: #{inspect(value)} is not an email"
  end

  defp format_error(value, "date-time", at) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> nil
      _ -> "#{at}: #{inspect(value)} is not a date-time"
    end
  end

  defp format_error(value, "uri", at) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) -> nil
      _ -> "#{at}: #{inspect(value)} is not a uri"
    end
  end

  defp format_error(_, _, _), do: nil

  defp number_errors(value, schema, at) when is_number(value) do
    [
      if(schema["minimum"] && value < schema["minimum"], do: "#{at}: below #{schema["minimum"]}"),
      if(schema["maximum"] && value > schema["maximum"], do: "#{at}: above #{schema["maximum"]}")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp number_errors(_, _, _), do: []

  defp array_errors(value, schema, at) when is_list(value) do
    size = length(value)

    [
      if(schema["minItems"] && size < schema["minItems"],
        do: ["#{at}: fewer than #{schema["minItems"]} items"]
      ),
      if(schema["maxItems"] && size > schema["maxItems"],
        do: ["#{at}: more than #{schema["maxItems"]} items"]
      ),
      if(schema["items"],
        do:
          value
          |> Enum.with_index()
          |> Enum.flat_map(fn {v, i} -> errors(v, schema["items"], "#{at}/#{i}") end)
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> List.flatten()
  end

  defp array_errors(_, _, _), do: []

  defp object_errors(value, schema, at) when is_map(value) do
    props = schema["properties"] || %{}

    missing =
      for name <- schema["required"] || [],
          not Map.has_key?(value, name),
          do: "#{at}: missing #{name}"

    known =
      Enum.flat_map(value, fn {k, v} ->
        cond do
          Map.has_key?(props, k) ->
            errors(v, props[k], "#{at}/#{k}")

          schema["additionalProperties"] == false ->
            ["#{at}: unknown property #{k}"]

          is_map(schema["additionalProperties"]) ->
            errors(v, schema["additionalProperties"], "#{at}/#{k}")

          true ->
            []
        end
      end)

    missing ++ known
  end

  defp object_errors(_, _, _), do: []

  def validate!(value, schema, where) do
    case errors(value, schema) do
      [] ->
        :ok

      problems ->
        flunk("#{where} does not match the contract: #{Enum.join(Enum.take(problems, 5), "; ")}")
    end
  end

  # --- examples -------------------------------------------------------------------------------

  @doc "A deterministic instance of `schema`: objects get every property when `full`, else the required ones."
  def example(schema, full \\ true)
  def example(nil, _), do: %{}

  def example(schema, full) do
    s = resolve(schema)

    cond do
      match?([_], s["allOf"]) ->
        example(hd(s["allOf"]), full)

      Enum.all?(~w(type enum anyOf oneOf properties), &(not Map.has_key?(s, &1))) ->
        %{}

      s["anyOf"] || s["oneOf"] ->
        variants = s["anyOf"] || s["oneOf"]
        non_null = Enum.reject(variants, &(resolve(&1)["type"] == "null"))
        example(hd(if(non_null == [], do: variants, else: non_null)), full)

      Map.has_key?(s, "enum") ->
        s["enum"] |> Enum.reject(&is_nil/1) |> List.first()

      true ->
        kind =
          (s["type"] || "object")
          |> List.wrap()
          |> Enum.reject(&(&1 == "null"))
          |> List.first("null")

        of_type(kind, s, full)
    end
  end

  defp of_type("string", s, _) do
    case @formats[s["format"]] do
      nil ->
        "value"
        |> String.pad_trailing(s["minLength"] || 0, "x")
        |> String.slice(0, s["maxLength"] || 10_000)

      value ->
        value
    end
  end

  defp of_type("integer", s, _),
    do: trunc(s["minimum"] || if((s["maximum"] || 1) >= 1, do: 1, else: 0))

  defp of_type("number", s, _), do: (s["minimum"] || 1) * 1.0
  defp of_type("boolean", _, _), do: false
  defp of_type("null", _, _), do: nil

  defp of_type("array", s, full) do
    count = max(s["minItems"] || 1, 1)
    count = min(count, s["maxItems"] || count)
    if count == 0, do: [], else: for(_ <- 1..count, do: example(s["items"] || %{}, full))
  end

  defp of_type("object", s, full) do
    required = s["required"] || []

    for {k, v} <- s["properties"] || %{},
        full or k in required,
        into: %{},
        do: {k, example(v, full)}
  end
end

defmodule BillionSend.Test.Mock do
  @moduledoc """
  The transport the tests hand to the client (`{BillionSend.Test.Mock, mock}`):
  checks every request against the contract and answers it.
  """
  @behaviour BillionSend.Transport

  alias BillionSend.{Request, Response}
  alias BillionSend.Test.Contract
  alias BillionSend.Test.Contract.Operation

  defmodule Call do
    @moduledoc false
    defstruct [:operation, :request, :path_params, :query, :body]

    def header(%__MODULE__{request: req}, name) do
      Enum.find_value(req.headers, fn {k, v} ->
        if String.downcase(k) == String.downcase(name), do: v
      end)
    end

    def key(%__MODULE__{operation: op}), do: Operation.key(op)
  end

  def start do
    {:ok, pid} = Agent.start_link(fn -> %{calls: [], queued: %{}, streams: %{}} end)
    pid
  end

  def calls(mock), do: Agent.get(mock, &Enum.reverse(&1.calls))

  @doc "Queues one answer for an operation (FIFO), instead of the generated example."
  def respond(mock, method, path, status \\ 200, opts \\ []) do
    op = Contract.operation(method, path)
    json = Keyword.get(opts, :json)

    cond do
      json != nil and status >= 400 ->
        Contract.validate!(json, %{"$ref" => "#/components/schemas/ErrorResponse"}, "queued error")

      json != nil ->
        schema =
          get_in(op.spec, ["responses", to_string(status), "content", "application/json", "schema"]) ||
            elem(Operation.success(op), 2)

        if schema, do: Contract.validate!(json, schema, "queued #{method} #{path} answer")

      true ->
        :ok
    end

    headers =
      if(json != nil, do: %{"content-type" => "application/json"}, else: %{})
      |> Map.merge(
        Map.new(Keyword.get(opts, :headers, []), fn {k, v} -> {String.downcase(k), v} end)
      )

    answer = %{
      status: status,
      headers: headers,
      body: Keyword.get(opts, :body) || if(json == nil, do: "", else: JSON.encode!(json)),
      chunks: Keyword.get(opts, :chunks),
      error: Keyword.get(opts, :error)
    }

    queue(mock, Operation.key(op), answer)
  end

  def error(mock, method, path, status, name, message, opts \\ []) do
    respond(mock, method, path, status,
      json: %{"statusCode" => status, "name" => name, "message" => message},
      headers: Keyword.get(opts, :headers, [])
    )
  end

  @doc "Queues a failure without an answer."
  def fail(mock, method, path, error),
    do: queue(mock, Operation.key(Contract.operation(method, path)), {:fail, error})

  defp queue(mock, key, answer) do
    Agent.update(mock, fn s -> update_in(s, [:queued, Access.key(key, [])], &(&1 ++ [answer])) end)
  end

  @impl true
  def request(mock, %Request{} = req) do
    case handle(mock, req) do
      {:fail, error} -> {:error, error}
      answer -> {:ok, %Response{status: answer.status, headers: answer.headers, body: answer.body}}
    end
  end

  @impl true
  def open_stream(mock, %Request{} = req) do
    case handle(mock, req) do
      {:fail, error} ->
        {:error, error}

      answer ->
        chunks = answer.chunks || if(answer.body == "", do: [], else: [answer.body])
        ref = make_ref()

        Agent.update(
          mock,
          &put_in(&1, [:streams, ref], %{chunks: chunks, error: answer.error, closed: false})
        )

        {:ok, %Response{status: answer.status, headers: answer.headers}, ref}
    end
  end

  @impl true
  def next_chunk(mock, ref) do
    Agent.get_and_update(mock, fn s ->
      case s.streams[ref] do
        %{chunks: [chunk | rest]} -> {{:ok, chunk, ref}, put_in(s, [:streams, ref, :chunks], rest)}
        %{error: nil} -> {:done, s}
        %{error: error} -> {{:error, error}, put_in(s, [:streams, ref, :error], nil)}
      end
    end)
  end

  @impl true
  def close_stream(mock, ref) do
    Agent.update(mock, &put_in(&1, [:streams, ref, :closed], true))
  end

  def streams_closed?(mock),
    do: Agent.get(mock, fn s -> Enum.all?(s.streams, fn {_, v} -> v.closed end) end)

  defp handle(mock, %Request{url: url} = req) do
    unless String.starts_with?(url, Contract.base_url()),
      do: Contract.flunk("request outside #{Contract.base_url()}: #{url}")

    uri = URI.parse(url)
    {op, path_params} = Contract.find(req.method, uri.path)

    query =
      (uri.query || "")
      |> URI.query_decoder()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    body = if req.body, do: decode_body(req)
    call = %Call{operation: op, request: req, path_params: path_params, query: query, body: body}
    Agent.update(mock, fn s -> %{s | calls: [call | s.calls]} end)
    check(op, call)

    Agent.get_and_update(mock, fn s ->
      case Map.get(s.queued, Operation.key(op), []) do
        [answer | rest] -> {answer, put_in(s, [:queued, Operation.key(op)], rest)}
        [] -> {generated(op), s}
      end
    end)
  end

  # A JSON body as is; a multipart form as a map of its fields (a file as its
  # content), which is how the form's schema describes it.
  defp decode_body(%Request{headers: headers, body: body}) do
    type =
      Enum.find_value(headers, "", fn {k, v} -> if String.downcase(k) == "content-type", do: v end)

    case type do
      "multipart/form-data; boundary=" <> boundary -> multipart_fields(body, boundary)
      _ -> JSON.decode!(body)
    end
  end

  defp multipart_fields(body, boundary) do
    delimiter = "--" <> boundary

    body
    |> String.split(delimiter)
    |> Enum.drop(1)
    |> Enum.reject(&String.starts_with?(&1, "--"))
    |> Map.new(fn part ->
      part = part |> String.replace_prefix("\r\n", "") |> String.replace_suffix("\r\n", "")
      [head, value] = String.split(part, "\r\n\r\n", parts: 2)
      [_, name] = Regex.run(~r/name="([^"]+)"/, head)
      {name, value}
    end)
  end

  defp check(op, call) do
    where = "#{op.method} #{op.path}"
    auth = Call.header(call, "authorization")

    cond do
      Operation.needs_auth?(op) and auth != "Bearer #{Contract.api_key()}" ->
        Contract.flunk("#{where}: no API key")

      not Operation.needs_auth?(op) and auth != nil ->
        Contract.flunk("#{where}: sends an API key where none is taken")

      true ->
        :ok
    end

    for p <- Operation.params(op, "path"),
        do:
          Contract.validate!(
            call.path_params[p["name"]],
            p["schema"] || %{},
            "#{where} path #{p["name"]}"
          )

    known = Map.new(Operation.params(op, "query"), &{&1["name"], &1})

    for {name, values} <- call.query do
      unless Map.has_key?(known, name),
        do: Contract.flunk("#{where}: unknown query parameter #{name}")

      if length(values) > 1, do: Contract.flunk("#{where}: query parameter #{name} sent twice")
      enum = Contract.resolve(known[name]["schema"] || %{})["enum"]

      if enum && hd(values) not in enum,
        do: Contract.flunk("#{where}: #{name}=#{hd(values)} is not one of #{inspect(enum)}")
    end

    for p <- Operation.params(op, "query") ++ Operation.params(op, "header"), p["required"] do
      present =
        if p["in"] == "query",
          do: Map.has_key?(call.query, p["name"]),
          else: Call.header(call, p["name"])

      unless present, do: Contract.flunk("#{where}: missing required #{p["in"]} #{p["name"]}")
    end

    if Operation.idempotency_key?(op) and Call.header(call, "idempotency-key") == nil,
      do: Contract.flunk("#{where}: no Idempotency-Key")

    case {op.spec["requestBody"], call.body} do
      {nil, nil} ->
        :ok

      {nil, _} ->
        Contract.flunk("#{where}: sends a body the operation does not take")

      {%{"required" => true}, nil} ->
        Contract.flunk("#{where}: no body")

      {_, nil} ->
        :ok

      {body, value} ->
        [{_, %{"schema" => schema}}] = Enum.to_list(body["content"])
        Contract.validate!(value, schema, "#{where} body")
    end
  end

  defp generated(op) do
    case Operation.success(op) do
      {status, "text/event-stream", _} ->
        %{
          status: status,
          headers: %{"content-type" => "text/event-stream"},
          body: "",
          chunks: [],
          error: nil
        }

      {status, _, nil} ->
        %{status: status, headers: %{}, body: "", chunks: nil, error: nil}

      {status, _, schema} ->
        json = Contract.example(schema)
        Contract.validate!(json, schema, "generated #{op.method} #{op.path} answer")

        %{
          status: status,
          headers: %{"content-type" => "application/json"},
          body: JSON.encode!(json),
          chunks: nil,
          error: nil
        }
    end
  end
end
