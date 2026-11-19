defmodule BillionSend.ApiChangesTest do
  @moduledoc """
  The API changes of the 0.2.2 snapshot, against the published contract: domain
  suppressions (an entry without an address, `kind`, `removable`, the `domains`
  field of a batch), the return-path default and its 422, the per-domain standing
  in `GET /deliverability`, the `domain_sending_paused` refusal and the webhook
  payload that names the scope.
  """
  use ExUnit.Case, async: true

  import BillionSend.Test.Helpers
  alias BillionSend.Test.{Contract, Mock}

  @domain_entry %{
    "id" => "8c3f3f5a-5e77-4c6a-9c79-2b4d5e6f7a81",
    "object" => "suppression",
    "email" => nil,
    "kind" => "domain",
    "domain" => "blocked.example",
    "removable" => true,
    "origin" => "manual",
    "source_id" => nil,
    "created_at" => "2026-11-19T09:00:00.000Z"
  }

  @email_entry %{
    "id" => "9d404060-6f88-4d7b-8d8a-3c5e6f708192",
    "object" => "suppression",
    "email" => "ada@example.com",
    "kind" => "email",
    "domain" => nil,
    "removable" => false,
    "origin" => "bounce",
    "source_id" => nil,
    "created_at" => "2026-11-19T09:00:00.000Z"
  }

  defp list_page(entries, more) do
    %{"object" => "list", "has_more" => more, "data" => entries}
  end

  describe "suppressions" do
    test "an entry for a domain has no address and reads as it came" do
      {client, mock} = client()
      Mock.respond(mock, "GET", "/suppressions/{id}", 200, json: @domain_entry)

      assert {:ok, entry} = BillionSend.Suppressions.get(client, @domain_entry["id"])
      assert entry == @domain_entry
      assert entry["email"] == nil
      assert %{"kind" => "domain", "domain" => "blocked.example", "removable" => true} = entry
    end

    test "an entry that cannot be removed says so" do
      {client, mock} = client()
      Mock.respond(mock, "GET", "/suppressions/{id}", 200, json: @email_entry)

      assert {:ok, %{"removable" => false, "kind" => "email", "domain" => nil}} =
               BillionSend.Suppressions.get(client, @email_entry["id"])
    end

    test "a domain is blocked with `domain` and no email" do
      {client, mock} = client()
      Mock.respond(mock, "POST", "/suppressions", 201, json: @domain_entry)

      assert {:ok, %{"kind" => "domain"}} =
               BillionSend.Suppressions.create(client, %{domain: "blocked.example"})

      assert [%{body: %{"domain" => "blocked.example"} = body}] = Mock.calls(mock)
      refute Map.has_key?(body, "email")
    end

    test "a batch takes domains alone, and emails with domains" do
      {client, mock} = client()
      answer = list_page([@domain_entry, @email_entry], false)
      Mock.respond(mock, "POST", "/suppressions/batch/add", 200, json: answer)
      Mock.respond(mock, "POST", "/suppressions/batch/add", 200, json: answer)

      assert {:ok, %{"data" => [_, _]}} =
               BillionSend.Suppressions.Batch.add(client, %{domains: ["blocked.example"]})

      assert {:ok, _} =
               BillionSend.Suppressions.Batch.add(client, %{
                 emails: ["ada@example.com"],
                 domains: ["blocked.example"],
                 origin: "manual"
               })

      assert [%{body: first}, %{body: second}] = Mock.calls(mock)
      assert first == %{"domains" => ["blocked.example"]}

      assert second == %{
               "emails" => ["ada@example.com"],
               "domains" => ["blocked.example"],
               "origin" => "manual"
             }
    end

    test "the list takes `kind`, and only the published values" do
      {client, mock} = client()
      Mock.respond(mock, "GET", "/suppressions", 200, json: list_page([@domain_entry], false))

      assert {:ok, %{"data" => [%{"email" => nil}]}} =
               BillionSend.Suppressions.list(client, kind: "domain")

      assert [%{query: %{"kind" => ["domain"]}}] = Mock.calls(mock)

      assert_raise ExUnit.AssertionError, ~r/kind/, fn ->
        BillionSend.Suppressions.list(client, kind: "everything")
      end
    end

    test "list_all walks entries without an address and keeps `kind` on every page" do
      {client, mock} = client()
      second = Map.put(@domain_entry, "id", "ae515171-7099-4e8c-9e9b-4d6f70819203")
      Mock.respond(mock, "GET", "/suppressions", 200, json: list_page([@domain_entry], true))
      Mock.respond(mock, "GET", "/suppressions", 200, json: list_page([second], false))

      entries = client |> BillionSend.Suppressions.list_all(kind: "all", limit: 1) |> Enum.to_list()

      assert Enum.map(entries, & &1["domain"]) == ["blocked.example", "blocked.example"]
      assert Enum.all?(entries, &is_nil(&1["email"]))

      assert Enum.map(Mock.calls(mock), & &1.query) == [
               %{"kind" => ["all"], "limit" => ["1"]},
               %{"kind" => ["all"], "limit" => ["1"], "after" => [@domain_entry["id"]]}
             ]
    end
  end

  describe "domains" do
    test "the return path is not set by the SDK, so the API's default (bounce) applies" do
      {client, mock} = client()
      Mock.respond(mock, "POST", "/domains")
      assert {:ok, _} = BillionSend.Domains.create(client, %{name: "acme.dev"})
      assert [%{body: body}] = Mock.calls(mock)
      assert body == %{"name" => "acme.dev"}

      default =
        get_in(Contract.spec(), [
          "components",
          "schemas",
          "CreateDomainRequest",
          "properties",
          "custom_return_path",
          "default"
        ])

      assert default == "bounce"
    end

    test "changing the return path of a domain is refused with 422, as a validation error" do
      {client, mock} = client(max_retries: 0)

      Mock.error(
        mock,
        "PATCH",
        "/domains/{id}",
        422,
        "validation_error",
        "custom_return_path cannot be changed"
      )

      assert {:error, %BillionSend.ValidationError{status_code: 422, name: "validation_error"}} =
               BillionSend.Domains.update(client, id(), %{custom_return_path: "send"})

      assert [%{body: %{"custom_return_path" => "send"}}] = Mock.calls(mock)
    end
  end

  describe "deliverability" do
    test "answers each sending domain's standing, a shared-domain row with no id included" do
      {client, mock} = client()

      {_, _, schema} =
        Contract.operation("GET", "/deliverability") |> Contract.Operation.success()

      domain = fn id, name, status, paused_by ->
        %{
          "domain_id" => id,
          "domain" => name,
          "status" => status,
          "tier" => status,
          "paused_by" => paused_by,
          "emails_sent" => 250,
          "hard_bounce_rate" => 0.012,
          "complaint_rate" => 0.0004,
          "recent_hard_bounce_rate" => 0.03,
          "recent_complaint_rate" => 0.0,
          "pause_margin" => -0.2,
          "hard_bounces" => 3,
          "complaints" => 0,
          "delivered" => 240,
          "window_days" => 7
        }
      end

      published =
        schema
        |> Contract.example()
        |> Map.put("domains", [
          domain.(id(), "acme.dev", "paused", "both"),
          domain.(nil, nil, "ok", nil)
        ])

      Mock.respond(mock, "GET", "/deliverability", 200, json: published)
      assert {:ok, answer} = BillionSend.Deliverability.get(client)
      assert [%{"paused_by" => "both", "domain" => "acme.dev"}, shared] = answer["domains"]
      assert %{"domain_id" => nil, "domain" => nil, "paused_by" => nil} = shared
      assert answer == JSON.decode!(JSON.encode!(published))
    end

    test "an answer without `domains` is refused by the contract" do
      {client, mock} = client()

      {_, _, schema} =
        Contract.operation("GET", "/deliverability") |> Contract.Operation.success()

      assert_raise ExUnit.AssertionError, ~r/domains/, fn ->
        Mock.respond(mock, "GET", "/deliverability", 200,
          json: schema |> Contract.example() |> Map.delete("domains")
        )
      end

      _ = client
    end
  end

  describe "a paused sending domain" do
    test "403 domain_sending_paused is a permission error that names itself, like sending_paused" do
      {client, mock} = client(max_retries: 0)

      for {name, message} <- [
            {"domain_sending_paused", "Sending from acme.dev is paused"},
            {"sending_paused", "Sending is paused for the team"}
          ] do
        Mock.error(mock, "POST", "/emails", 403, name, message)

        assert {:error, %BillionSend.PermissionDeniedError{} = error} =
                 BillionSend.Emails.send(client, %{
                   from: "a@acme.dev",
                   to: ["b@example.com"],
                   subject: "s",
                   html: "<p>x</p>"
                 })

        assert error.status_code == 403
        assert error.name == name
        assert Exception.message(error) == "403 #{name}: #{message}"
      end
    end
  end

  describe "deliverability webhooks" do
    @secret "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"

    defp signed(payload, now) do
      key = Base.decode64!("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
      content = "msg_dp.#{now}.#{payload}"
      sig = :crypto.mac(:hmac, :sha256, key, content) |> Base.encode64()

      %{
        "webhook-id" => "msg_dp",
        "webhook-timestamp" => Integer.to_string(now),
        "webhook-signature" => "v1,#{sig}"
      }
    end

    for {type, scope, domain} <- [
          {"deliverability.paused", "domain", ~s({"id":"d1","name":"acme.dev"})},
          {"deliverability.warning", "team", "null"}
        ] do
      test "#{type} with scope #{scope} verifies and keeps `scope` and `domain`" do
        payload =
          ~s({"type":"#{unquote(type)}","created_at":"2026-11-19T09:00:00.000Z","data":{"scope":"#{unquote(scope)}","domain":#{unquote(domain)}}})

        assert {:ok, event} =
                 BillionSend.verify_webhook(payload, signed(payload, 1_800_000_000), @secret,
                   now: 1_800_000_000
                 )

        assert event["type"] == unquote(type)
        assert event["data"]["scope"] == unquote(scope)

        assert event["data"]["domain"] ==
                 if(unquote(scope) == "domain", do: %{"id" => "d1", "name" => "acme.dev"})
      end
    end
  end
end
