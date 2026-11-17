defmodule BillionSend.RetriesTest do
  use ExUnit.Case, async: true

  import BillionSend.Test.Helpers
  alias BillionSend.Test.Mock
  alias BillionSend.Test.Mock.Call

  @email %{"from" => "a@acme.com", "to" => ["b@example.com"], "subject" => "s", "text" => "t"}

  test "a GET is retried on 5xx with backoff" do
    {client, mock} = client()
    Mock.error(mock, "GET", "/domains", 503, "unavailable", "Try later")
    Mock.error(mock, "GET", "/domains", 500, "internal", "Oops")
    assert {:ok, _} = BillionSend.Domains.list(client)
    assert length(Mock.calls(mock)) == 3
    [first, second] = sleeps()
    assert first in 375..500
    assert second in 750..1000
  end

  test "gives up after max_retries" do
    {client, mock} = client()
    for _ <- 1..3, do: Mock.error(mock, "GET", "/domains", 503, "unavailable", "Try later")
    assert {:error, %BillionSend.APIError{}} = BillionSend.Domains.list(client)
    assert length(Mock.calls(mock)) == 3
  end

  test "max_retries 0 sends once" do
    {client, mock} = client(max_retries: 0)
    Mock.error(mock, "GET", "/domains", 503, "unavailable", "Try later")
    assert {:error, _} = BillionSend.Domains.list(client)
    assert length(Mock.calls(mock)) == 1
  end

  test "a POST without a key is not retried" do
    {client, mock} = client()
    Mock.error(mock, "POST", "/domains", 503, "unavailable", "Try later")
    assert {:error, _} = BillionSend.Domains.create(client, %{"name" => "acme.com"})
    assert length(Mock.calls(mock)) == 1
  end

  test "a send is retried with the same generated key" do
    {client, mock} = client(max_retries: 3)
    Mock.error(mock, "POST", "/emails", 503, "unavailable", "Try later")
    Mock.fail(mock, "POST", "/emails", %BillionSend.APIConnectionError{message: "Connection error"})
    assert {:ok, _} = BillionSend.Emails.send(client, @email)
    keys = Enum.map(Mock.calls(mock), &Call.header(&1, "idempotency-key"))
    assert length(keys) == 3
    assert length(Enum.uniq(keys)) == 1
  end

  test "two sends get two keys" do
    {client, mock} = client()
    {:ok, _} = BillionSend.Emails.send(client, @email)
    {:ok, _} = BillionSend.Emails.send(client, @email)
    [a, b] = Enum.map(Mock.calls(mock), &Call.header(&1, "idempotency-key"))
    assert a != b
  end

  test "Retry-After is honoured" do
    {client, mock} = client()

    Mock.error(mock, "GET", "/domains", 429, "rate_limit_exceeded", "Slow down",
      headers: [{"retry-after", "3"}]
    )

    assert {:ok, _} = BillionSend.Domains.list(client)
    assert sleeps() == [3000]
  end

  test "Retry-After as an HTTP date" do
    {client, mock} = client()
    at = DateTime.utc_now() |> DateTime.add(2) |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    Mock.error(mock, "GET", "/domains", 429, "rate_limit_exceeded", "Slow down",
      headers: [{"retry-after", at}]
    )

    assert {:ok, _} = BillionSend.Domains.list(client)
    [ms] = sleeps()
    assert ms <= 2000
  end

  test "a Retry-After over sixty seconds is returned at once" do
    {client, mock} = client()

    Mock.error(mock, "GET", "/domains", 429, "rate_limit_exceeded", "Slow down",
      headers: [{"retry-after", "61"}]
    )

    assert {:error, %BillionSend.RateLimitError{}} = BillionSend.Domains.list(client)
    assert length(Mock.calls(mock)) == 1
    assert sleeps() == []
  end

  test "concurrent_idempotent_requests is retried when keyed" do
    {client, mock} = client()
    Mock.error(mock, "POST", "/emails", 409, "concurrent_idempotent_requests", "Still running")
    assert {:ok, _} = BillionSend.Emails.send(client, @email)
    assert length(Mock.calls(mock)) == 2
  end

  test "another conflict is not retried" do
    {client, mock} = client()

    Mock.error(
      mock,
      "POST",
      "/emails",
      409,
      "invalid_idempotent_request",
      "Key reused with another body"
    )

    assert {:error, %BillionSend.ConflictError{}} = BillionSend.Emails.send(client, @email)
    assert length(Mock.calls(mock)) == 1
  end

  test "a 4xx is not retried" do
    {client, mock} = client()
    Mock.error(mock, "GET", "/domains/{id}", 404, "not_found", "No such domain")
    assert {:error, %BillionSend.NotFoundError{}} = BillionSend.Domains.get(client, id())
    assert length(Mock.calls(mock)) == 1
  end

  test "a failure without an answer is retried for a GET" do
    {client, mock} = client()
    Mock.fail(mock, "GET", "/domains", %BillionSend.APITimeoutError{message: "Request timed out"})
    assert {:ok, _} = BillionSend.Domains.list(client)
    assert length(Mock.calls(mock)) == 2
  end

  test "backoff is capped at eight seconds" do
    {client, mock} = client(max_retries: 6)
    for _ <- 1..6, do: Mock.error(mock, "GET", "/domains", 503, "unavailable", "Try later")
    assert {:ok, _} = BillionSend.Domains.list(client)
    waits = sleeps()
    assert Enum.max(waits) <= 8000
    assert List.last(waits) >= 6000
  end
end
