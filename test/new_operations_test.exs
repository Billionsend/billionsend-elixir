defmodule BillionSend.NewOperationsTest do
  use ExUnit.Case, async: true

  import BillionSend.Test.Helpers
  alias BillionSend.Multipart
  alias BillionSend.Test.Mock
  alias BillionSend.Test.Mock.Call

  test "usage is read in the published shape: emails.daily and emails.monthly" do
    {client, mock} = client()
    full = BillionSend.Test.Contract.example(%{"$ref" => "#/components/schemas/UsageResponse"})

    published =
      full
      |> put_in(["emails", "daily", "limit"], 100)
      |> put_in(["emails", "monthly", "used"], 340)
      |> put_in(["contacts", "limit"], nil)

    Mock.respond(mock, "GET", "/usage", 200, json: published)

    assert {:ok, answer} = BillionSend.Usage.get(client)
    assert get_in(answer, ["emails", "daily", "limit"]) == 100
    assert get_in(answer, ["emails", "monthly", "used"]) == 340
    assert answer["contacts"]["limit"] == nil
  end

  test "an answer in the old usage shape is not the contract" do
    {_client, mock} = client()

    assert_raise ExUnit.AssertionError, ~r/does not match the contract/, fn ->
      Mock.respond(mock, "GET", "/usage", 200, json: %{"limits" => %{"emails_per_day" => 100}})
    end
  end

  test "the two removed operations are gone and the replacement is there" do
    # function_exported?/3 answers false for a module that is not loaded yet.
    Enum.each([BillionSend.Unsubscribes, BillionSend.Webhooks], &Code.ensure_loaded!/1)

    refute function_exported?(BillionSend.Unsubscribes, :delete, 2)
    refute function_exported?(BillionSend.Unsubscribes, :delete, 3)
    refute function_exported?(BillionSend.Webhooks, :rotate, 2)
    refute function_exported?(BillionSend.Webhooks, :rotate, 3)
    refute function_exported?(BillionSend.Webhooks, :rotate, 4)
    assert function_exported?(BillionSend.Webhooks, :rotate_signing_secret, 2)
  end

  describe "contacts import (multipart/form-data)" do
    defp fields(%Call{request: req}) do
      {_, type} = Enum.find(req.headers, fn {k, _} -> String.downcase(k) == "content-type" end)
      assert "multipart/form-data; boundary=" <> boundary = type
      assert String.length(boundary) > 20

      req.body
      |> String.split("--" <> boundary)
      |> Enum.drop(1)
      |> Enum.reject(&String.starts_with?(&1, "--"))
      |> Map.new(fn part ->
        [head, value] =
          part
          |> String.trim_leading("\r\n")
          |> String.replace_suffix("\r\n", "")
          |> String.split("\r\n\r\n", parts: 2)

        [_, name] = Regex.run(~r/name="([^"]+)"/, head)
        {name, {head, value}}
      end)
    end

    test "sends the file as a part and the structured fields as JSON text" do
      {client, mock} = client()
      csv = "Email,First Name\r\nada@example.com,Ada\r\n"

      assert {:ok, _} =
               BillionSend.Contacts.Imports.create(client, %{
                 file: {"contacts.csv", csv, "text/csv"},
                 column_map: %{email: "Email", first_name: "First Name"},
                 segments: [%{id: id()}],
                 on_conflict: "skip",
                 topics: nil
               })

      [call] = Mock.calls(mock)
      parts = fields(call)

      assert {file_head, ^csv} = parts["file"]
      assert file_head =~ ~s(filename="contacts.csv")
      assert file_head =~ "Content-Type: text/csv"
      assert {_, "skip"} = parts["on_conflict"]
      assert {_, column_map} = parts["column_map"]
      assert JSON.decode!(column_map) == %{"email" => "Email", "first_name" => "First Name"}
      assert {_, segments} = parts["segments"]
      assert JSON.decode!(segments) == [%{"id" => id()}]
      refute Map.has_key?(parts, "topics")
      refute Call.header(call, "content-type") =~ "json"
    end

    test "a file part keeps every byte of its content" do
      binary = <<0, 255, 13, 10, 13, 10, "--x", 13, 10>>
      {type, body} = Multipart.encode(%{file: {"a.bin", binary}})
      assert "multipart/form-data; boundary=" <> boundary = type
      assert body =~ binary
      assert String.ends_with?(body, "--" <> boundary <> "--\r\n")
      assert body =~ "Content-Type: application/octet-stream"
    end

    test "a quote or line break in a name cannot end the header early" do
      {_, body} = Multipart.encode(%{file: {"a\"b\r\nX-Evil: 1.csv", "x"}})
      assert body =~ ~s(filename="a\\"bX-Evil: 1.csv")
      refute body =~ "\r\nX-Evil"
    end

    test "is not retried without an idempotency key, like any other POST" do
      {client, mock} = client()
      Mock.error(mock, "POST", "/contacts/imports", 503, "unavailable", "Try later")

      assert {:error, %BillionSend.APIError{}} =
               BillionSend.Contacts.Imports.create(client, %{file: {"c.csv", "Email\r\n"}})

      assert length(Mock.calls(mock)) == 1
    end
  end
end
