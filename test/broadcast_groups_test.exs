defmodule BillionSend.BroadcastGroupsTest do
  @moduledoc """
  The broadcast group operations (one send from several sending domains) and the
  optional body of `Automations.stop`: the request each function sends and the
  answer it reads. Every request is also checked against the OpenAPI snapshot by
  the contract mock.
  """
  use ExUnit.Case, async: true

  import BillionSend.Test.Helpers
  alias BillionSend.Test.{Contract, Mock}
  alias BillionSend.Test.Contract.Operation

  @id "8c3f3f5a-5e77-4c6a-9c79-2b4d5e6f7a81"
  @domains [@id, "9d404060-6f88-4d7b-8d8a-3c5e6f708192"]

  # The document's own example of what the operation answers.
  defp answer(method, path) do
    {_, _, schema} = Operation.success(Contract.operation(method, path))
    Contract.example(schema)
  end

  defp respond(mock, method, path, status \\ 200) do
    published = answer(method, path)
    Mock.respond(mock, method, path, status, json: published)
    published
  end

  describe "BillionSend.BroadcastGroups" do
    test "create sends the domains and the shared content" do
      {client, mock} = client()
      published = respond(mock, "POST", "/broadcast-groups", 201)

      assert {:ok, ^published} =
               BillionSend.BroadcastGroups.create(client, %{
                 name: "Spring sale",
                 domain_ids: @domains,
                 from_local_part: "news",
                 subject: "Spring sale",
                 html: "<p>Hello</p>"
               })

      assert [%{request: %{method: "POST"}, body: body}] = Mock.calls(mock)
      assert body["domain_ids"] == @domains
      assert body["from_local_part"] == "news"
      assert Mock.violations(mock) == []
    end

    test "list takes the cursor options and list_all walks every page" do
      {client, mock} = client()
      respond(mock, "GET", "/broadcast-groups")
      assert {:ok, %{"data" => _}} = BillionSend.BroadcastGroups.list(client, limit: 5, after: @id)
      assert [%{request: %{method: "GET"}}] = Mock.calls(mock)
      assert Mock.violations(mock) == []

      {client, mock} = client()
      page = answer("GET", "/broadcast-groups")
      item = fn id -> put_in(hd(page["data"])["id"], id) end
      first = %{page | "has_more" => true, "data" => [item.(@id)]}
      last = %{page | "has_more" => false, "data" => [item.(List.last(@domains))]}
      Mock.respond(mock, "GET", "/broadcast-groups", 200, json: first)
      Mock.respond(mock, "GET", "/broadcast-groups", 200, json: last)

      ids = client |> BillionSend.BroadcastGroups.list_all(limit: 1) |> Enum.map(& &1["id"])
      assert ids == @domains
    end

    test "get, remove and cancel address the group by its id" do
      {client, mock} = client()
      get = respond(mock, "GET", "/broadcast-groups/{id}")
      remove = respond(mock, "DELETE", "/broadcast-groups/{id}")
      cancel = respond(mock, "POST", "/broadcast-groups/{id}/cancel")

      assert {:ok, ^get} = BillionSend.BroadcastGroups.get(client, @id)
      assert {:ok, ^remove} = BillionSend.BroadcastGroups.remove(client, @id)
      assert {:ok, ^cancel} = BillionSend.BroadcastGroups.cancel(client, @id)

      urls = Enum.map(Mock.calls(mock), & &1.request.url)
      base = "https://api.test.billionsend.com/broadcast-groups/" <> @id
      assert urls == [base, base, base <> "/cancel"]

      assert Mock.violations(mock) == []
    end

    test "update sends only the fields given" do
      {client, mock} = client()
      published = respond(mock, "PATCH", "/broadcast-groups/{id}")

      assert {:ok, ^published} =
               BillionSend.BroadcastGroups.update(client, @id, %{subject: "Summer sale"})

      assert [%{request: %{method: "PATCH"}, body: %{"subject" => "Summer sale"} = body}] =
               Mock.calls(mock)

      assert map_size(body) == 1
      assert Mock.violations(mock) == []
    end

    test "send takes a schedule, or none" do
      {client, mock} = client()
      published = respond(mock, "POST", "/broadcast-groups/{id}/send")
      Mock.respond(mock, "POST", "/broadcast-groups/{id}/send", 200, json: published)

      assert {:ok, ^published} =
               BillionSend.BroadcastGroups.send(client, @id, %{scheduled_at: "in 1 hour"})

      assert {:ok, ^published} = BillionSend.BroadcastGroups.send(client, @id)

      assert [%{body: %{"scheduled_at" => "in 1 hour"}}, %{body: second}] = Mock.calls(mock)
      assert second in [nil, %{}]
      assert Mock.violations(mock) == []
    end
  end

  describe "BillionSend.Automations.stop" do
    test "cancel_runs goes in the body" do
      {client, mock} = client()
      published = respond(mock, "POST", "/automations/{id}/stop")

      assert {:ok, ^published} =
               BillionSend.Automations.stop(client, @id, %{cancel_runs: true})

      assert [%{body: %{"cancel_runs" => true}}] = Mock.calls(mock)
      assert Mock.violations(mock) == []
    end

    test "the body may be left out, and options may stand in its place" do
      {client, mock} = client()
      published = respond(mock, "POST", "/automations/{id}/stop")
      Mock.respond(mock, "POST", "/automations/{id}/stop", 200, json: published)

      assert {:ok, ^published} = BillionSend.Automations.stop(client, @id)

      assert {:ok, ^published} =
               BillionSend.Automations.stop(client, @id, extra_headers: [{"x-test", "1"}])

      assert [%{body: first}, %{body: second}] = Mock.calls(mock)
      assert first in [nil, %{}]
      assert second in [nil, %{}]
      assert Mock.violations(mock) == []
    end
  end
end
