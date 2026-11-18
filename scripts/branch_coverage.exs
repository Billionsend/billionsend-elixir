# Branch coverage of the SDK's hand-written code.
#
# Erlang's `cover` (which `mix test --cover` and excoveralls use) measures lines,
# function clauses and functions, not branches. This script reads the coverage
# export of a test run and counts, for every construct that chooses between
# outcomes, how many of its outcomes ran:
#
#   * each clause of a `case`, `cond`, `receive`, `try` (rescue / catch / else),
#     `with ... else`, and of an anonymous function;
#   * the `do` and the `else` of an `if` / `unless` (an `if` without `else` counts
#     its `do` only: the missing else has no line of its own to look at);
#   * the `do` body of a `with` (its success path);
#   * each clause of a function defined in several clauses (`def` / `defp`);
#   * the right-hand side of `and`, `or`, `&&`, `||` when it sits on a line of its
#     own (on the same line it cannot be told apart from the left).
#
# An outcome ran when the first line of its body, which `cover` instruments, was
# executed at least once. This is an approximation: two outcomes written on one
# line count as one, and an outcome whose body has no instrumented line is left out
# (reported as "not measurable"). Code inside `quote` (the error structs) is counted
# on the lines of the modules it expands into.
#
#   mix test --cover --export-coverage handwritten
#   mix run --no-start scripts/branch_coverage.exs cover/handwritten.coverdata [--threshold 95] [--list]

Mix.ensure_application!(:tools)

defmodule BranchCoverage do
  @files ~w(lib/billionsend.ex lib/billionsend/client.ex lib/billionsend/errors.ex
            lib/billionsend/multipart.ex lib/billionsend/pagination.ex lib/billionsend/streaming.ex
            lib/billionsend/transport.ex lib/billionsend/transport/sse_connection.ex
            lib/billionsend/webhook.ex)

  def run(args) do
    {opts, [export], _} = OptionParser.parse(args, strict: [threshold: :float, list: :boolean])
    lines = line_counts(export)

    results =
      for file <- @files do
        {file, branches(file, Map.get(lines, Path.expand(file), %{}))}
      end

    IO.puts(
      "branch coverage of the hand-written code (see the header of this script for the method)\n"
    )

    {hit, total, skipped} =
      Enum.reduce(results, {0, 0, 0}, fn {file, bs}, {h, t, s} ->
        measurable = Enum.filter(bs, &(&1.state != :unmeasurable))
        covered = Enum.count(measurable, &(&1.state == :hit))
        skipped = length(bs) - length(measurable)

        pct = if measurable == [], do: 100.0, else: covered * 100 / length(measurable)

        IO.puts(
          "#{String.pad_trailing(file, 44)} #{covered}/#{length(measurable)}  #{:erlang.float_to_binary(pct, decimals: 1)}%"
        )

        if opts[:list] do
          for b <- measurable,
              b.state == :miss,
              do: IO.puts("    not run: #{file}:#{b.line}  #{b.kind}")
        end

        {h + covered, t + length(measurable), s + skipped}
      end)

    pct = if total == 0, do: 100.0, else: hit * 100 / total

    IO.puts(
      "\ntotal #{hit}/#{total} = #{:erlang.float_to_binary(pct, decimals: 1)}% (#{skipped} outcomes not measurable)"
    )

    if opts[:threshold] && pct < opts[:threshold] do
      IO.puts(:stderr, "branch coverage #{Float.round(pct, 1)}% is below #{opts[:threshold]}%")
      System.halt(1)
    end
  end

  # file => %{line => calls}, summed over every module of the file; only the
  # lines `cover` instruments are present.
  defp line_counts(export) do
    :cover.start()
    :ok = :cover.import(String.to_charlist(export))

    # Only the SDK's own modules are loaded here (the test support code is not).
    for module <- :cover.imported_modules(), Code.ensure_loaded?(module), reduce: %{} do
      acc ->
        source = module.module_info(:compile)[:source] |> to_string()
        {:ok, lines} = :cover.analyse(module, :calls, :line)

        Enum.reduce(lines, acc, fn
          {{_, 0}, _}, acc ->
            acc

          {{_, line}, calls}, acc ->
            update_in(acc, [Access.key(source, %{}), Access.key(line, 0)], &(&1 + calls))
        end)
    end
  end

  defp branches(file, counts) do
    ast = file |> File.read!() |> Code.string_to_quoted!()
    clauses = clause_groups(ast)

    arms =
      ast
      |> collect()
      |> Kernel.++(clauses)
      |> Enum.map(fn {kind, line, last} -> classify(kind, line, last, counts) end)

    Enum.sort_by(arms, & &1.line)
  end

  # {kind, first line, last line} of the body of every outcome.
  defp collect(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc -> {node, outcomes(node) ++ acc} end)

    acc
  end

  defp outcomes({construct, _, [_ | _] = args}) when construct in [:case, :cond, :receive, :try] do
    blocks = args |> List.last() |> block_keywords()

    for {_key, clauses} <- blocks,
        is_list(clauses),
        arrow <- clauses,
        match?({:->, _, _}, arrow),
        do: arm("#{construct}", arrow)
  end

  defp outcomes({:with, _, args}) do
    last = List.last(args)

    case block_keywords(last) do
      [] ->
        []

      blocks ->
        body = for {:do, body} <- blocks, do: span("with do", body)

        elses =
          for {:else, clauses} <- blocks,
              arrow <- clauses,
              match?({:->, _, _}, arrow),
              do: arm("with else", arrow)

        body ++ elses
    end
  end

  defp outcomes({construct, _, [_cond, blocks]}) when construct in [:if, :unless] do
    for {key, body} <- block_keywords(blocks),
        key in [:do, :else],
        do: span("#{construct} #{key}", body)
  end

  defp outcomes({:fn, _, clauses}), do: for(arrow <- clauses, do: arm("fn clause", arrow))

  defp outcomes({op, meta, [left, right]}) when op in [:and, :or, :&&, :||] do
    if line(right) && line(left) && line(right) > line(left),
      do: [{"#{op} right", meta[:line] && line(right), last_line(right)}],
      else: []
  end

  defp outcomes(_), do: []

  defp block_keywords(args) when is_list(args), do: if(Keyword.keyword?(args), do: args, else: [])
  defp block_keywords(_), do: []

  defp arm(kind, {:->, meta, [_pattern, body]}) do
    {kind, line(body) || meta[:line], last_line(body) || meta[:line]}
  end

  defp span(kind, body), do: {kind, line(body), last_line(body)}

  # Every `def` / `defp` written in more than one clause: each clause is an outcome.
  defp clause_groups(ast) do
    {_, defs} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head | rest]} = node, acc when kind in [:def, :defp, :defmacro] ->
          {node, [{kind, head_key(head), body_of(rest)} | acc]}

        node, acc ->
          {node, acc}
      end)

    defs
    |> Enum.filter(fn {_, key, body} -> key != nil and body != nil end)
    |> Enum.group_by(fn {kind, key, _} -> {kind, key} end)
    |> Enum.filter(fn {_, group} -> length(group) > 1 end)
    |> Enum.flat_map(fn {_, group} ->
      for {_, _, body} <- group, do: {"function clause", line(body), last_line(body)}
    end)
  end

  defp head_key({:when, _, [head | _]}), do: head_key(head)
  defp head_key({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp head_key({name, _, nil}) when is_atom(name), do: {name, 0}
  defp head_key(_), do: nil

  defp body_of([[{:do, body} | _]]), do: body
  defp body_of([kw]) when is_list(kw), do: Keyword.get(kw, :do)
  defp body_of(_), do: nil

  defp line(ast) do
    {_, lines} =
      Macro.prewalk(ast, [], fn
        {_, meta, _} = node, acc when is_list(meta) ->
          {node, if(meta[:line], do: [meta[:line] | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    if lines == [], do: nil, else: Enum.min(lines)
  end

  defp last_line(ast) do
    {_, lines} =
      Macro.prewalk(ast, [], fn
        {_, meta, _} = node, acc when is_list(meta) ->
          {node, if(meta[:line], do: [meta[:line] | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    if lines == [], do: nil, else: Enum.max(lines)
  end

  defp classify(kind, first, last, counts) do
    case first && Enum.find(first..(last || first), &Map.has_key?(counts, &1)) do
      nil -> %{kind: kind, line: first || 0, state: :unmeasurable}
      at -> %{kind: kind, line: first, state: if(counts[at] > 0, do: :hit, else: :miss)}
    end
  end
end

BranchCoverage.run(System.argv())
