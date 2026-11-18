# Generates lib/billionsend/resources.ex from the OpenAPI snapshot.
#
# One function per operation, in a module per group of operationIds: the
# operationId's dotted path names the module and the function, camelCase
# written in snake_case (emails.receiving.attachments.list is
# BillionSend.Emails.Receiving.Attachments.list). Each function returns
# {:ok, answer} or {:error, error}; its `!` twin returns the answer or raises.
# Lists with after/before cursors also get `<name>_all`, a lazy Stream of every
# item.
#
#   elixir scripts/generate.exs          # rewrite the generated file
#   elixir scripts/generate.exs --check  # fail if it differs from the snapshot

defmodule Generate do
  @root Path.expand("..", __DIR__)
  @snapshot Path.join(@root, "openapi/api.openapi.json")
  @out Path.join(@root, "lib/billionsend/resources.ex")
  @methods ~w(get put post patch delete)
  @header_kwargs %{"x-batch-validation" => :batch_validation}
  @reserved ~w(do end fn when and or not in true false nil after else catch rescue client opts params)

  def run(args) do
    spec = @snapshot |> File.read!() |> JSON.decode!()

    text =
      spec
      |> operations()
      |> render()
      |> Code.format_string!(line_length: 100)
      |> IO.iodata_to_binary()

    text = text <> "\n"

    if "--check" in args do
      if File.exists?(@out) and File.read!(@out) == text do
        IO.puts("generated file matches the snapshot")
      else
        IO.puts(:stderr, "lib/billionsend/resources.ex is stale: run `elixir scripts/generate.exs`")
        System.halt(1)
      end
    else
      File.write!(@out, text)
      IO.puts("wrote lib/billionsend/resources.ex")
    end
  end

  def snake(text) do
    text
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.replace(~r/[^0-9a-zA-Z]+/, "_")
    |> String.trim("_")
    |> String.downcase()
  end

  def pascal(text) do
    text
    |> String.split(~r/[^0-9a-zA-Z]+/, trim: true)
    |> Enum.map_join(fn <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest end)
  end

  defp var(text) do
    name = snake(text)
    if name in @reserved, do: name <> "_", else: name
  end

  defp resolve(spec, %{"$ref" => ref}),
    do: resolve(spec, spec["components"]["schemas"][List.last(String.split(ref, "/"))])

  defp resolve(_spec, schema), do: schema || %{}

  defp has_id?(spec, schema) do
    case schema["anyOf"] || schema["oneOf"] do
      nil -> Map.has_key?(schema["properties"] || %{}, "id")
      branches -> Enum.all?(branches, &has_id?(spec, resolve(spec, &1)))
    end
  end

  def operations(spec) do
    # Sorted: a map's iteration order differs between OTP releases.
    found =
      for(
        {path, item} <- spec["paths"],
        {m, op} <- item,
        m in @methods,
        do: {String.upcase(m), path, op}
      )
      |> Enum.sort_by(fn {m, path, _} ->
        {path, Enum.find_index(@methods, &(&1 == String.downcase(m)))}
      end)

    ids = Enum.map(found, fn {_, _, op} -> op["operationId"] end)

    if nil in ids or length(Enum.uniq(ids)) != length(ids),
      do: raise("every operation needs an operationId, each one different")

    Enum.map(found, fn {method, path, op} ->
      parts = String.split(op["operationId"], ".")
      {group, [last]} = Enum.split(parts, -1)
      if group == [], do: raise("#{op["operationId"]}: an operation needs a group")
      params = op["parameters"] || []

      by = fn where -> Enum.filter(params, &(&1["in"] == where)) end

      path_params =
        Regex.scan(~r/\{(\w+)\}/, path, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(fn name ->
          unless Enum.any?(by.("path"), &(&1["name"] == name)),
            do: raise("#{method} #{path}: path parameters do not match the template")

          {name, var(name)}
        end)

      query =
        Enum.map(by.("query"), fn p ->
          {p["name"], String.to_atom(snake(p["name"])), p["required"] == true}
        end)

      headers =
        by.("header")
        |> Enum.reject(&(String.downcase(&1["name"]) == "idempotency-key"))
        |> Enum.map(fn p ->
          key =
            @header_kwargs[String.downcase(p["name"])] ||
              String.to_atom(snake(String.replace_prefix(p["name"], "x-", "")))

          {p["name"], key, p["required"] == true}
        end)

      body = op["requestBody"]

      # JSON, or a multipart form (a file upload); no operation takes both.
      multipart = body != nil and Map.has_key?(body["content"], "multipart/form-data")

      body_schema =
        if body,
          do:
            resolve(
              spec,
              get_in(body, [
                "content",
                if(multipart, do: "multipart/form-data", else: "application/json"),
                "schema"
              ])
            ),
          else: %{}

      body_required =
        body != nil and
          (body["required"] == true or (body_schema["required"] || []) != [] or
             "array" in List.wrap(body_schema["type"]))

      success =
        op["responses"]
        |> Enum.filter(fn {code, _} -> String.starts_with?(code, "2") end)
        |> Enum.sort()

      stream? =
        Enum.any?(success, fn {_, r} -> Map.has_key?(r["content"] || %{}, "text/event-stream") end)

      json =
        for {_, r} <- success,
            schema = get_in(r, ["content", "application/json", "schema"]),
            do: schema

      names = Enum.map(query, &elem(&1, 0))

      paginated =
        not stream? and "after" in names and "before" in names and length(json) == 1 and
          (fn ->
             page = resolve(spec, hd(json))
             props = page["properties"] || %{}
             items = resolve(spec, get_in(props, ["data", "items"]) || %{})
             Map.has_key?(props, "has_more") and has_id?(spec, items)
           end).()

      %{
        method: method,
        path: path,
        module: Enum.map(group, &pascal/1),
        name: snake(last),
        summary: op["summary"] || "",
        description: op["description"] || "",
        path_params: path_params,
        query: query,
        headers: headers,
        body: body != nil,
        multipart: multipart,
        body_required: body_required,
        body_omit_when_none: body != nil and body["required"] == false,
        idempotent: Enum.any?(by.("header"), &(String.downcase(&1["name"]) == "idempotency-key")),
        auth: Map.get(op, "security", spec["security"]) != [],
        stream: stream?,
        paginated: paginated
      }
    end)
  end

  defp module_name(parts), do: Enum.join(["BillionSend" | parts], ".")

  def render(ops) do
    by_module = Enum.group_by(ops, & &1.module)

    modules =
      by_module
      |> Map.keys()
      |> Enum.flat_map(fn parts -> for i <- 1..length(parts), do: Enum.take(parts, i) end)
      |> Enum.uniq()
      |> Enum.sort()

    kernel = Kernel.__info__(:functions)

    body =
      Enum.map_join(modules, "\n\n", fn parts ->
        mod_ops = Map.get(by_module, parts, [])
        functions = Enum.flat_map(mod_ops, &function_names/1)
        clashes = Enum.filter(functions, &(&1 in kernel))

        except =
          if clashes == [],
            do: "",
            else:
              "  import Kernel, except: [#{Enum.map_join(clashes, ", ", fn {n, a} -> "#{n}: #{a}" end)}]\n\n"

        children =
          modules
          |> Enum.filter(
            &(length(&1) == length(parts) + 1 and Enum.take(&1, length(parts)) == parts)
          )
          |> Enum.map(&("`" <> module_name(&1) <> "`"))

        doc =
          "Operations on #{parts |> Enum.map(&snake/1) |> Enum.join(" ") |> String.replace("_", " ")}." <>
            if(children == [], do: "", else: " See also #{Enum.join(children, ", ")}.")

        """
        defmodule #{module_name(parts)} do
          @moduledoc #{heredoc(doc)}
        #{except}#{Enum.map_join(mod_ops, "\n", &function/1)}
        end
        """
      end)

    resource_list = Enum.map_join(modules, ", ", &module_name/1)

    """
    # Generated by scripts/generate.exs from openapi/api.openapi.json. Do not edit.

    #{body}

    defmodule BillionSend.Resources do
      @moduledoc false

      @doc false
      def modules, do: [#{resource_list}]
    end
    """
  end

  defp function_names(op) do
    arity = 1 + length(op.path_params) + if(op.body, do: 1, else: 0)
    base = String.to_atom(op.name)
    bang = String.to_atom(op.name <> "!")
    names = [{base, arity}, {base, arity + 1}, {bang, arity}, {bang, arity + 1}]

    if op.paginated do
      all = String.to_atom(op.name <> "_all")
      names ++ [{all, arity}, {all, arity + 1}]
    else
      names
    end
  end

  defp heredoc(text) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"\"\"", "\\\"\\\"\\\"")
      |> String.replace("\#{", "\\\#{")

    "\"\"\"\n#{escaped}\n\"\"\""
  end

  defp path_expr(op) do
    expr =
      Enum.reduce(op.path_params, op.path, fn {name, v}, acc ->
        String.replace(acc, "{#{name}}", "\#{BillionSend.Client.encode_path(#{v})}")
      end)

    "\"#{expr}\""
  end

  defp args(op, opts_default \\ true) do
    ["client"] ++
      Enum.map(op.path_params, &elem(&1, 1)) ++
      body_arg(op, opts_default) ++ [if(opts_default, do: "opts \\\\ []", else: "opts")]
  end

  defp body_arg(%{body: false}, _), do: []
  defp body_arg(%{body_required: true}, _), do: ["params"]
  defp body_arg(_, true), do: ["params \\\\ nil"]
  defp body_arg(_, false), do: ["params"]

  defp opt_docs(op) do
    lines =
      Enum.map(op.query, fn {name, key, req} ->
        "  * `#{inspect(key)}`#{if req, do: " (required)", else: ""} - query `#{name}`"
      end) ++
        Enum.map(op.headers, fn {name, key, req} ->
          "  * `#{inspect(key)}`#{if req, do: " (required)", else: ""} - header `#{name}`"
        end) ++
        if(op.idempotent,
          do: ["  * `:idempotency_key` - see \"Sending once\" in the README"],
          else: []
        ) ++
        if(op.stream,
          do: [
            "  * `:last_event_id` - resume after this position",
            "  * `:max_reconnects` - default 5"
          ],
          else: []
        ) ++
        ["  * `:extra_headers`, `:timeout`"]

    "Options:\n\n" <> Enum.join(lines, "\n")
  end

  defp spec_line(op, returns) do
    arg_types =
      ["BillionSend.Client.t()"] ++
        Enum.map(op.path_params, fn _ -> "String.t()" end) ++
        if(op.body,
          do: [if(op.multipart, do: "map() | keyword()", else: "map() | list() | nil")],
          else: []
        ) ++
        ["keyword()"]

    "@spec #{op.name}(#{Enum.join(arg_types, ", ")}) :: #{returns}"
  end

  defp function(op) do
    doc =
      [
        if(op.summary == "", do: nil, else: String.trim_trailing(op.summary, ".") <> "."),
        if(op.description == "", do: nil, else: op.description),
        if(op.idempotent,
          do:
            "Sent with an Idempotency-Key: `:idempotency_key` when given, else one made up for this call, so that its retries never send twice.",
          else: nil
        ),
        if(op.multipart,
          do:
            "Sent as `multipart/form-data`: `params` holds the form's fields. A file is `{filename, content}` or `{filename, content, content_type}`; a map or list is sent as its JSON text; see `BillionSend.Multipart`.",
          else: nil
        ),
        "`#{op.method} #{op.path}`",
        opt_docs(op)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    names = Enum.map(op.path_params, &elem(&1, 1))

    call_args =
      Enum.join(["client"] ++ names ++ if(op.body, do: ["params"], else: []) ++ ["opts"], ", ")

    if op.stream, do: stream_function(op, doc, call_args), else: plain_function(op, doc, call_args)
  end

  defp plain_function(op, doc, call_args) do
    required = for {_, key, true} <- op.query ++ op.headers, do: key

    query =
      Enum.map_join(op.query, ", ", fn {name, key, _} -> "{#{inspect(name)}, #{inspect(key)}}" end)

    headers =
      Enum.map_join(op.headers, ", ", fn {name, key, _} -> "{#{inspect(name)}, #{inspect(key)}}" end)

    spec =
      [
        if(op.query != [], do: "query: [#{query}]"),
        if(op.headers != [], do: "headers: [#{headers}]"),
        if(required != [], do: "required: #{inspect(required)}"),
        if(op.body, do: if(op.multipart, do: "multipart: params", else: "body: params")),
        if(op.idempotent, do: "idempotent: true, extra: [:idempotency_key]"),
        if(not op.auth, do: "auth: false")
      ]
      |> Enum.reject(&is_nil/1)

    spec_text = if spec == [], do: "[]", else: "[" <> Enum.join(spec, ", ") <> "]"

    paginator =
      if op.paginated do
        page_args =
          Enum.join(
            ["client"] ++
              Enum.map(op.path_params, &elem(&1, 1)) ++
              ["Keyword.merge(opts, after: page_after, before: page_before)"],
            ", "
          )

        """

          @doc \"\"\"
          Every item of `#{op.name}`, as a lazy Stream that fetches pages as it goes.

          Walks in the list's own order, from `:after` (or the first page) on; pass
          `:before` instead to walk the other way. Raises the errors `#{op.name}!` raises.
          \"\"\"
          @spec #{op.name}_all(#{Enum.join(["BillionSend.Client.t()"] ++ Enum.map(op.path_params, fn _ -> "String.t()" end) ++ ["keyword()"], ", ")}) :: Enumerable.t()
          def #{op.name}_all(#{Enum.join(args(op), ", ")}) do
            BillionSend.Pagination.stream(
              fn page_after, page_before -> #{op.name}(#{page_args}) end,
              Keyword.get(opts, :after),
              Keyword.get(opts, :before)
            )
          end
        """
      else
        ""
      end

    """
      @doc #{heredoc(doc)}
      #{spec_line(op, "{:ok, term()} | {:error, BillionSend.Errors.t()}")}
      def #{op.name}(#{Enum.join(args(op), ", ")}) do
        #{optional_body(op)}BillionSend.Client.call(client, #{inspect(op.method)}, #{path_expr(op)}, opts, #{spec_text})
      end

      @doc "Like `#{op.name}/#{length(args(op))}`, but returns the answer or raises."
      #{String.replace(spec_line(op, "term()"), "@spec #{op.name}(", "@spec #{op.name}!(")}
      def #{op.name}!(#{Enum.join(args(op), ", ")}) do
        BillionSend.Client.unwrap!(#{op.name}(#{call_args}))
      end
    #{paginator}
    """
  end

  # An optional body may be left out: `update(client, id, timeout: 5_000)`.
  defp optional_body(%{body: true, body_required: false} = op) do
    "{params, opts} = BillionSend.Client.optional_body(params, opts, #{op.body_omit_when_none})\n"
  end

  defp optional_body(_), do: ""

  defp stream_function(op, doc, call_args) do
    query =
      op.query
      |> Enum.reject(fn {name, _, _} -> name == "last_event_id" end)
      |> Enum.map_join(", ", fn {name, key, _} ->
        "{#{inspect(name)}, Keyword.get(opts, #{inspect(key)})}"
      end)

    allowed =
      (Enum.map(op.query, &elem(&1, 1)) ++
         [:last_event_id, :max_reconnects, :extra_headers, :timeout])
      |> Enum.uniq()

    """
      @doc #{heredoc(doc <> "\n\nReturns `{:ok, stream}`, a lazy Enumerable of `BillionSend.InboxStreamEvent` and `BillionSend.StreamGapEvent` structs (see `BillionSend.EventStream`), or `{:error, error}` when the API refuses the stream.")}
      #{spec_line(op, "{:ok, Enumerable.t()} | {:error, BillionSend.Errors.t()}")}
      def #{op.name}(#{Enum.join(args(op), ", ")}) do
        BillionSend.Client.check_opts!(opts, #{inspect(allowed)}, [])
        BillionSend.EventStream.open(client, #{path_expr(op)}, [#{query}], opts)
      end

      @doc "Like `#{op.name}/#{length(args(op))}`, but returns the stream or raises."
      #{String.replace(spec_line(op, "Enumerable.t()"), "@spec #{op.name}(", "@spec #{op.name}!(")}
      def #{op.name}!(#{Enum.join(args(op), ", ")}) do
        BillionSend.Client.unwrap!(#{op.name}(#{call_args}))
      end
    """
  end
end

Generate.run(System.argv())
