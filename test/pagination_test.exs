defmodule BillionSend.PaginationTest do
  use ExUnit.Case, async: true

  import BillionSend.Test.Helpers
  alias BillionSend.Test.{Contract, Mock}

  defp page(ids, more) do
    {_, _, schema} = Contract.operation("GET", "/contacts") |> Contract.Operation.success()
    item = hd(Contract.example(schema)["data"])
    %{"object" => "list", "has_more" => more, "data" => Enum.map(ids, &Map.put(item, "id", &1))}
  end

  @a "00000000-0000-4000-8000-000000000001"
  @b "00000000-0000-4000-8000-000000000002"
  @c "00000000-0000-4000-8000-000000000003"

  test "walks every page forward by the last id" do
    {client, mock} = client()
    Mock.respond(mock, "GET", "/contacts", 200, json: page([@a, @b], true))
    Mock.respond(mock, "GET", "/contacts", 200, json: page([@c], false))
    assert client |> BillionSend.Contacts.list_all(limit: 2) |> Enum.map(& &1["id"]) == [@a, @b, @c]

    assert Enum.map(Mock.calls(mock), & &1.query) == [
             %{"limit" => ["2"]},
             %{"limit" => ["2"], "after" => [@b]}
           ]
  end

  test "walks backward from before by the first id" do
    {client, mock} = client()
    Mock.respond(mock, "GET", "/contacts", 200, json: page([@a, @b], true))
    Mock.respond(mock, "GET", "/contacts", 200, json: page([], true))

    ids =
      client
      |> BillionSend.Contacts.list_all(before: "00000000-0000-4000-8000-000000000009")
      |> Enum.map(& &1["id"])

    assert ids == [@a, @b]
    assert List.last(Mock.calls(mock)).query["before"] == [@a]
  end

  test "is lazy" do
    {client, mock} = client()
    Mock.respond(mock, "GET", "/contacts", 200, json: page([@a], true))
    stream = BillionSend.Contacts.list_all(client)
    assert Mock.calls(mock) == []
    assert [_] = Enum.take(stream, 1)
    assert length(Mock.calls(mock)) == 1
  end

  test "raises what the ! function raises" do
    {client, mock} = client(max_retries: 0)
    Mock.error(mock, "GET", "/contacts", 403, "forbidden", "No")

    assert_raise BillionSend.PermissionDeniedError, fn ->
      client |> BillionSend.Contacts.list_all() |> Enum.to_list()
    end
  end
end
