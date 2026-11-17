defmodule BillionSend.ClientTest do
  # Reads and writes environment variables.
  use ExUnit.Case, async: false

  import BillionSend.Test.Helpers
  alias BillionSend.Test.{Contract, Mock}
  alias BillionSend.Test.Mock.Call

  defp with_env(values, fun) do
    saved = Map.new(values, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(values, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)

    try do
      fun.()
    after
      Enum.each(saved, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
    end
  end

  test "reads the key and base URL from the environment" do
    with_env(
      %{"BILLIONSEND_API_KEY" => "bs_env", "BILLIONSEND_BASE_URL" => "https://api.example.test/"},
      fn ->
        client = BillionSend.client()
        assert client.api_key == "bs_env"
        assert client.base_url == "https://api.example.test"
      end
    )
  end

  test "defaults to the public API" do
    with_env(%{"BILLIONSEND_API_KEY" => nil, "BILLIONSEND_BASE_URL" => nil}, fn ->
      client = BillionSend.client(api_key: "bs_x")
      assert client.base_url == "https://api.billionsend.com"
      assert client.timeout == 60_000
      assert client.max_retries == 2
      refute inspect(client) =~ "bs_x"
    end)
  end

  test "a request without a key fails before sending" do
    with_env(%{"BILLIONSEND_API_KEY" => nil}, fn ->
      {client, mock} = client(api_key: nil)

      assert {:error, %BillionSend.AuthenticationError{name: "missing_api_key", status_code: nil}} =
               BillionSend.Domains.list(client)

      assert Mock.calls(mock) == []
    end)
  end

  test "agent signup goes without a key" do
    with_env(%{"BILLIONSEND_API_KEY" => nil}, fn ->
      {client, mock} = client(api_key: nil)

      assert {:ok, _} =
               BillionSend.Agent.signup(client, %{human_email: "owner@example.com", name: "Scout"})

      assert Call.header(List.last(Mock.calls(mock)), "authorization") == nil
    end)
  end

  test "negative max_retries is refused" do
    assert_raise ArgumentError, fn -> BillionSend.client(api_key: "k", max_retries: -1) end
  end

  test "headers: user agent and overrides" do
    {client, mock} = client(default_headers: [{"x-team-tag", "a"}])
    {:ok, _} = BillionSend.Domains.list(client, extra_headers: [{"X-Team-Tag", "b"}])
    call = List.last(Mock.calls(mock))
    assert Call.header(call, "user-agent") == "billionsend-elixir/#{BillionSend.version()}"
    assert Call.header(call, "accept") == "application/json"
    assert for({k, v} <- call.request.headers, String.downcase(k) == "x-team-tag", do: v) == ["b"]
  end

  test "path segments are encoded and addresses keep their @" do
    {client, mock} = client()
    {:ok, _} = BillionSend.Inboxes.get(client, "support@example.com")

    assert List.last(Mock.calls(mock)).request.url ==
             "#{Contract.base_url()}/inboxes/support@example.com"

    assert BillionSend.Client.encode_path("a/b c") == "a%2Fb%20c"
  end

  test "emails.metrics and its group live side by side" do
    {client, mock} = client()
    {:ok, _} = BillionSend.Emails.metrics(client, metrics: ["sent", "delivered"])
    assert List.last(Mock.calls(mock)).query == %{"metrics" => ["sent,delivered"]}
    {:ok, _} = BillionSend.Emails.Metrics.links(client, limit: 5)
    assert List.last(Mock.calls(mock)).request.url =~ "/emails/metrics/links?limit=5"
  end

  test "booleans and unset values in the query" do
    {client, mock} = client()
    {:ok, _} = BillionSend.Emails.Receiving.list(client, unread: true, limit: 5, inbox_id: nil)
    assert List.last(Mock.calls(mock)).query == %{"unread" => ["true"], "limit" => ["5"]}
  end

  test "unknown and missing options are refused before sending" do
    {client, mock} = client()

    assert_raise ArgumentError, ~r/unknown options \[:limt\]/, fn ->
      BillionSend.Domains.list(client, limt: 5)
    end

    assert Mock.calls(mock) == []
  end

  test "answers are maps with string keys" do
    {client, _} = client()
    {:ok, domain} = BillionSend.Domains.get(client, id())
    assert is_map(domain)
    assert Enum.all?(Map.keys(domain), &is_binary/1)
  end

  test "an optional body may be left out, with or without options" do
    {client, mock} = client()
    {:ok, _} = BillionSend.Domains.verify(client, id())
    {:ok, _} = BillionSend.Domains.verify(client, id(), timeout: 5_000)
    assert length(Mock.calls(mock)) == 2
  end

  test "the caller's idempotency key is sent" do
    {client, mock} = client()
    email = %{from: "a@acme.com", to: ["b@example.com"], subject: "s", text: "t"}
    {:ok, _} = BillionSend.Emails.send(client, email, idempotency_key: "order-1")
    assert Call.header(List.last(Mock.calls(mock)), "idempotency-key") == "order-1"
  end

  test "a non-JSON success is an error" do
    {client, mock} = client()

    Mock.respond(mock, "GET", "/domains", 200,
      body: "<html>",
      headers: [{"content-type", "text/html"}]
    )

    assert {:error, %BillionSend.Error{message: "Expected a JSON answer, got text/html"}} =
             BillionSend.Domains.list(client)
  end

  test "the ! functions return the answer or raise" do
    {client, mock} = client(max_retries: 0)
    assert is_map(BillionSend.Domains.list!(client))
    Mock.error(mock, "GET", "/domains", 404, "not_found", "No such list")
    error = assert_raise BillionSend.NotFoundError, fn -> BillionSend.Domains.list!(client) end
    assert Exception.message(error) == "404 not_found: No such list"
  end
end
