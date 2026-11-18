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
    # Two waits, none after the last failure.
    assert length(sleeps()) == 2
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

  defp http_date(seconds_from_now) do
    DateTime.utc_now()
    |> DateTime.add(seconds_from_now)
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  describe "Retry-After" do
    # {header, the wait in milliseconds as a range}
    for {header, range} <- [
          {"3", 3000..3000},
          {"1.5", 1500..1500},
          {" 4 ", 4000..4000},
          {"0", 0..0},
          {"-5", 0..0},
          # Seconds in the text, a made-up pause when it is not a number or a date.
          {"soon", 375..500},
          {"", 375..500},
          {"5 seconds", 375..500},
          {"Wed, 99 Foo 2026 25:61:61 GMT", 375..500}
        ] do
      test "#{inspect(header)} on a 429 waits #{inspect(range)} ms" do
        {client, mock} = client()

        Mock.error(mock, "GET", "/domains", 429, "rate_limit_exceeded", "Slow down",
          headers: [{"retry-after", unquote(header)}]
        )

        assert {:ok, _} = BillionSend.Domains.list(client)
        assert [ms] = sleeps()
        assert ms in unquote(Macro.escape(range))
      end
    end

    test "an HTTP date is waited for until that moment, never longer" do
      {client, mock} = client()

      Mock.error(mock, "GET", "/domains", 429, "rate_limit_exceeded", "Slow down",
        headers: [{"retry-after", http_date(10)}]
      )

      assert {:ok, _} = BillionSend.Domains.list(client)
      assert [ms] = sleeps()
      assert ms in 8000..10_000
    end

    test "an HTTP date in the past means no wait" do
      {client, mock} = client()

      Mock.error(mock, "GET", "/domains", 429, "rate_limit_exceeded", "Slow down",
        headers: [{"retry-after", http_date(-30)}]
      )

      assert {:ok, _} = BillionSend.Domains.list(client)
      assert sleeps() == [0]
    end

    test "an HTTP date more than a minute away is returned at once, with its seconds" do
      {client, mock} = client()

      Mock.error(mock, "GET", "/domains", 429, "rate_limit_exceeded", "Slow down",
        headers: [{"retry-after", http_date(120)}]
      )

      assert {:error, %BillionSend.RateLimitError{retry_after: seconds}} =
               BillionSend.Domains.list(client)

      assert seconds > 100 and seconds <= 120
      assert length(Mock.calls(mock)) == 1
      assert sleeps() == []
    end

    test "a 503 that says when to come back is waited for, too" do
      {client, mock} = client()

      Mock.error(mock, "GET", "/domains", 503, "unavailable", "Try later",
        headers: [{"retry-after", "2"}]
      )

      assert {:ok, _} = BillionSend.Domains.list(client)
      assert sleeps() == [2000]
    end
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

  test "PUT and DELETE are retried, PATCH is not" do
    {client, mock} = client()
    Mock.error(mock, "DELETE", "/domains/{id}", 503, "unavailable", "Try later")
    assert {:ok, _} = BillionSend.Domains.delete(client, id())
    assert length(Mock.calls(mock)) == 2

    {client, mock} = client()
    Mock.error(mock, "PATCH", "/domains/{id}", 503, "unavailable", "Try later")

    assert {:error, %BillionSend.APIError{}} =
             BillionSend.Domains.update(client, id(), %{open_tracking: true})

    assert length(Mock.calls(mock)) == 1
  end

  test "a lost connection on a POST without a key is not retried" do
    {client, mock} = client()
    Mock.fail(mock, "POST", "/domains", %BillionSend.APIConnectionError{message: "reset"})

    assert {:error, %BillionSend.APIConnectionError{}} =
             BillionSend.Domains.create(client, %{name: "acme.com"})

    assert length(Mock.calls(mock)) == 1
    assert sleeps() == []
  end

  test "a timeout is retried like a lost connection, and its error survives the last attempt" do
    {client, mock} = client(max_retries: 1)

    for _ <- 1..2,
        do:
          Mock.fail(mock, "GET", "/domains", %BillionSend.APITimeoutError{
            message: "Request timed out"
          })

    assert {:error, %BillionSend.APITimeoutError{message: "Request timed out"}} =
             BillionSend.Domains.list(client)

    assert length(Mock.calls(mock)) == 2
    assert length(sleeps()) == 1
  end
end
