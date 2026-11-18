defmodule BillionSend.Test.Requests do
  @moduledoc """
  What a caller would pass for one operation of the contract, and what the API
  must receive for it, worked out from the OpenAPI document alone: the
  expectations are written out here (an id as itself, the one awkward string
  percent-encoded by hand), never by calling the SDK's own encoders.

  `build/2` takes an operation and a mode:

    * `:minimal` - only what the operation requires (the body's required
      fields, the required query and header parameters);
    * `:full` - every query and header parameter and every field of the body.
  """

  alias BillionSend.Test.Contract
  alias BillionSend.Test.Contract.Operation

  # One id that needs every kind of escaping, and what it must look like in a path.
  @awkward "a+b@x.com é/?#"
  @awkward_encoded "a%2Bb@x.com%20%C3%A9%2F%3F%23"

  # Header parameters the SDK takes as an option, by the header's name.
  @header_options %{"x-batch-validation" => :batch_validation}

  defstruct [
    :op,
    :paths,
    :path,
    :has_body,
    :body,
    :wire_body,
    :opts,
    :query,
    :headers,
    :key
  ]

  def uuid(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  def build(op, mode) do
    {paths, path} = path(op)
    full? = mode == :full

    params =
      for p <- Operation.params(op, "query"),
          full? or p["required"] == true,
          do: p

    stream? = stream?(op)

    query_opts =
      for {p, i} <- Enum.with_index(params), into: [] do
        {String.to_atom(p["name"]), param_value(Contract.resolve(p["schema"]), i)}
      end

    headers =
      for p <- Operation.params(op, "header"),
          String.downcase(p["name"]) != "idempotency-key",
          full? or p["required"] == true do
        {p["name"], Map.fetch!(@header_options, String.downcase(p["name"])),
         hd(Contract.resolve(p["schema"])["enum"])}
      end

    key = if full? and Operation.idempotency_key?(op), do: "key-" <> Operation.id(op)

    opts =
      query_opts ++
        Enum.map(headers, fn {_, option, value} -> {option, value} end) ++
        if(key, do: [idempotency_key: key], else: [])

    # What the API receives: a stream's resume position travels as the header.
    query =
      for {p, {_, value}} <- Enum.zip(params, query_opts),
          not (stream? and p["name"] == "last_event_id"),
          into: %{},
          do: {p["name"], [wire_text(value)]}

    expected_headers =
      Map.new(headers, fn {name, _, value} -> {String.downcase(name), value} end)
      |> then(fn h ->
        if stream? and Keyword.has_key?(query_opts, :last_event_id),
          do: Map.put(h, "last-event-id", query_opts[:last_event_id]),
          else: h
      end)

    {has_body, body, wire_body} = body(op, full?)

    %__MODULE__{
      op: op,
      paths: paths,
      path: path,
      has_body: has_body,
      body: body,
      wire_body: wire_body,
      opts: opts,
      query: query,
      headers: expected_headers,
      key: key
    }
  end

  @doc """
  The request of an operation called with its body alone, no options at all
  (the arity without `opts`), or nil when the operation has no body or needs an option.
  """
  def body_only(op) do
    r = build(op, :full)

    required =
      for p <- Operation.params(op, "query") ++ Operation.params(op, "header"), p["required"], do: p

    if r.has_body and required == [] do
      %{r | opts: [], query: %{}, headers: %{}, key: nil}
    end
  end

  def stream?(op), do: match?({_, "text/event-stream", _}, Operation.success(op))

  # The path parameters in order, and the path as it must be on the wire.
  defp path(op) do
    {values, wire} =
      op.names
      |> Enum.with_index(1)
      |> Enum.map(fn {name, i} ->
        schema = Enum.find(Operation.params(op, "path"), &(&1["name"] == name))["schema"]

        if Contract.resolve(schema)["format"] == "uuid",
          do: {uuid(i), uuid(i)},
          else: {@awkward, @awkward_encoded}
      end)
      |> Enum.unzip()

    path =
      Enum.reduce(Enum.zip(op.names, wire), op.path, fn {name, text}, acc ->
        String.replace(acc, "{#{name}}", text)
      end)

    {values, path}
  end

  defp param_value(%{"enum" => [first | _]}, _), do: first
  defp param_value(%{"format" => "uuid"}, i), do: uuid(100 + i)
  defp param_value(%{"format" => "date-time"}, _), do: "2026-01-01T00:00:00.000Z"
  defp param_value(%{"type" => "boolean"}, _), do: true
  defp param_value(%{"type" => "string"}, i), do: "value #{i}"

  defp param_value(%{"type" => "integer"} = s, _),
    do: min(max(s["minimum"] || 1, 3), s["maximum"] || 100)

  defp param_value(%{"type" => "array", "items" => items}, i) do
    case Contract.resolve(items) do
      %{"enum" => values} -> Enum.take(values, 2)
      %{"format" => "uuid"} -> [uuid(200 + i), uuid(300 + i)]
      _ -> ["a", "b"]
    end
  end

  # How a query value reads on the wire: a list is comma-separated.
  defp wire_text(values) when is_list(values), do: Enum.join(values, ",")
  defp wire_text(value), do: to_string(value)

  defp body(op, full?) do
    case op.spec["requestBody"] do
      nil ->
        {false, nil, nil}

      request_body ->
        [{media, %{"schema" => schema}}] = Enum.to_list(request_body["content"])
        required? = request_body["required"] == true or required_fields?(schema)

        cond do
          media == "multipart/form-data" ->
            form(schema, full?)

          not required? and not full? ->
            {false, nil, nil}

          true ->
            given = Contract.example(schema, full?)
            {true, given, JSON.decode!(JSON.encode!(given))}
        end
    end
  end

  defp required_fields?(schema) do
    s = Contract.resolve(schema)
    (s["required"] || []) != [] or "array" in List.wrap(s["type"])
  end

  # A form: the file as a part, every other field as text.
  defp form(schema, full?) do
    fields = Contract.example(schema, full?)
    csv = "Email\r\nada@example.com\r\n"
    given = Map.put(fields, "file", {"contacts.csv", csv, "text/csv"})

    wire =
      Map.new(fields, fn {k, v} ->
        {k, if(is_binary(v), do: v, else: JSON.encode!(v))}
      end)
      |> Map.put("file", csv)

    {true, given, wire}
  end

  @doc "The function an operation's id names: `emails.receiving.list` is `BillionSend.Emails.Receiving.list`."
  def target(op) do
    {group, [last]} = op |> Operation.id() |> String.split(".") |> Enum.split(-1)
    module = Module.concat([BillionSend | Enum.map(group, &upcase_first/1)])

    name =
      last
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.downcase()
      |> String.to_atom()

    {module, name}
  end

  defp upcase_first(text), do: String.upcase(String.first(text)) <> String.slice(text, 1..-1//1)

  @doc "Calls the operation's function (or its `!` twin) with the request's arguments."
  def call(client, %__MODULE__{} = r, bang \\ false) do
    {module, name} = target(r.op)
    name = if bang, do: String.to_atom("#{name}!"), else: name

    body_args =
      cond do
        r.has_body -> [r.body]
        r.op.spec["requestBody"] != nil and r.opts != [] -> [nil]
        true -> []
      end

    opts_args = if r.opts == [], do: [], else: [r.opts]
    apply(module, name, [client | r.paths] ++ body_args ++ opts_args)
  end

  @doc "Calls the operation's `_all` stream with the request's path parameters and options."
  def call_all(client, %__MODULE__{} = r) do
    {module, name} = target(r.op)
    opts_args = if r.opts == [], do: [], else: [r.opts]
    apply(module, String.to_atom("#{name}_all"), [client | r.paths] ++ opts_args)
  end

  @doc "A 4xx status the operation declares, else 404."
  def error_status(op) do
    declared =
      for {code, _} <- op.spec["responses"],
          code in ~w(400 403 404 409 410 422),
          do: String.to_integer(code)

    case Enum.sort(declared) do
      [first | _] -> first
      [] -> 404
    end
  end

  @doc "Whether an operation's page has `after` and `before`, so that it has an `_all` stream."
  def paged?(op) do
    names = Enum.map(Operation.params(op, "query"), & &1["name"])
    {_, media, _} = Operation.success(op)
    media == "application/json" and "after" in names and "before" in names
  end
end
