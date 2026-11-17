defmodule BillionSend.CoverageTest do
  @moduledoc """
  Every operation of the snapshot is reachable through the SDK, and nothing else is.

  Each operation is called through the contract mock by the function its
  operationId names (the group as the module, the last segment as the
  function, camelCase in snake_case), with its path parameters, an instance of
  its body schema and its required query and header parameters. The
  operations hit are compared with the snapshot, and the functions of the
  resource modules with the operations: an operation the SDK does not reach,
  or a function that is not an operation, fails.
  """
  use ExUnit.Case, async: true

  import BillionSend.Test.Helpers
  alias BillionSend.Test.{Contract, Mock}
  alias BillionSend.Test.Contract.Operation

  defp snake(text),
    do: text |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2") |> String.downcase()

  defp pascal(text), do: String.upcase(String.first(text)) <> String.slice(text, 1..-1//1)

  defp target(op) do
    {group, [last]} = op |> Operation.id() |> String.split(".") |> Enum.split(-1)
    {Module.concat([BillionSend | Enum.map(group, &pascal/1)]), String.to_atom(snake(last))}
  end

  defp invoke(client, op) do
    {module, function} = target(op)

    paths =
      Regex.scan(~r/\{(\w+)\}/, op.path, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(fn name ->
        p = Enum.find(Operation.params(op, "path"), &(&1["name"] == name))
        to_string(Contract.example(p["schema"] || %{}))
      end)

    body =
      case op.spec["requestBody"] do
        nil -> []
        b -> [Contract.example(get_in(b, ["content", "application/json", "schema"]), false)]
      end

    opts =
      for p <- Operation.params(op, "query") ++ Operation.params(op, "header"),
          p["required"],
          do: {required_key(p), Contract.example(p["schema"])}

    result = apply(module, function, [client | paths] ++ body ++ [opts])

    case result do
      {:ok, %Stream{} = stream} -> Enum.take(stream, 0)
      _ -> :ok
    end

    result
  end

  defp required_key(%{"name" => "x-batch-validation"}), do: :batch_validation

  defp required_key(%{"name" => name}),
    do: name |> String.replace_prefix("x-", "") |> snake() |> String.to_atom()

  test "every operation is reached and answers its schema" do
    {client, mock} = client()

    for op <- Contract.operations() do
      assert {:ok, _} = invoke(client, op), "#{Operation.id(op)} failed"
    end

    keys = Enum.map(Contract.operations(), &Operation.key/1)
    assert MapSet.new(Enum.map(Mock.calls(mock), &Mock.Call.key/1)) == MapSet.new(keys)
    assert length(Contract.operations()) == 139
  end

  test "every function of the resource modules is an operation, its ! twin or its _all stream" do
    ops = Contract.operations()
    expected = MapSet.new(ops, &target/1)
    paged = MapSet.new(for op <- ops, op.spec["operationId"] |> paged?(op), do: target(op))

    found =
      for module <- BillionSend.Resources.modules(),
          {name, _arity} <- module.__info__(:functions),
          into: MapSet.new() do
        text = Atom.to_string(name)

        cond do
          String.ends_with?(text, "!") ->
            base = String.to_atom(String.trim_trailing(text, "!"))
            assert {module, base} in expected, "#{inspect(module)}.#{text} twins no operation"
            {module, base}

          String.ends_with?(text, "_all") ->
            base = String.to_atom(String.trim_trailing(text, "_all"))
            assert {module, base} in paged, "#{inspect(module)}.#{text} pages no cursor list"
            {module, base}

          true ->
            {module, name}
        end
      end

    assert found == expected
  end

  defp paged?(_id, op) do
    names = Enum.map(Operation.params(op, "query"), & &1["name"])
    {_, media, _} = Operation.success(op)
    media == "application/json" and "after" in names and "before" in names
  end

  test "sending operations always carry an idempotency key, a new one each call" do
    keyed = Enum.filter(Contract.operations(), &Operation.idempotency_key?/1)
    assert length(keyed) == 8
    {client, mock} = client()
    Enum.each(keyed, &invoke(client, &1))
    keys = Enum.map(Mock.calls(mock), &Mock.Call.header(&1, "idempotency-key"))

    assert Enum.all?(
             keys,
             &(&1 =~
                 ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89ab][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\z/)
           ),
           inspect(keys)

    assert length(Enum.uniq(keys)) == length(keys)
  end
end
