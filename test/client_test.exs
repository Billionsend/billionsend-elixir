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

  test "the inbox filter of the received-mail list takes an inbox address as well as an id" do
    {client, mock} = client()
    {:ok, _} = BillionSend.Emails.Receiving.list(client, inbox_id: "agent@acme.billionsend.app")
    assert List.last(Mock.calls(mock)).query == %{"inbox_id" => ["agent@acme.billionsend.app"]}

    {:ok, _} =
      BillionSend.Emails.Receiving.list(client, inbox_id: "9b2f6a52-7a6e-4a53-9a4a-6f1d2d1f4f10")

    assert List.last(Mock.calls(mock)).query == %{
             "inbox_id" => ["9b2f6a52-7a6e-4a53-9a4a-6f1d2d1f4f10"]
           }
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

defmodule BillionSend.ClientOptionsTest do
  @moduledoc "How a client is built and what its requests carry, beyond the defaults."
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

  describe "the API key" do
    test "an explicit key wins over the environment" do
      with_env(%{"BILLIONSEND_API_KEY" => "bs_env"}, fn ->
        assert BillionSend.client(api_key: "bs_given").api_key == "bs_given"
        assert BillionSend.client().api_key == "bs_env"
      end)
    end

    test "surrounding whitespace and a trailing newline are not part of the key" do
      {client, mock} = client(api_key: nil)
      client = %{client | api_key: nil}
      assert {:error, %BillionSend.AuthenticationError{}} = BillionSend.Domains.list(client)

      with_env(%{"BILLIONSEND_API_KEY" => "#{Contract.api_key()}\n"}, fn ->
        from_env = BillionSend.client(transport: client.transport)
        assert from_env.api_key == Contract.api_key()
      end)

      given = BillionSend.client(api_key: "  #{Contract.api_key()}\r\n", transport: {Mock, mock})
      assert {:ok, _} = BillionSend.Domains.list(%{given | base_url: Contract.base_url()})

      assert Call.header(List.last(Mock.calls(mock)), "authorization") ==
               "Bearer " <> Contract.api_key()
    end

    test "a blank key falls back to the environment, and to no key at all" do
      with_env(%{"BILLIONSEND_API_KEY" => "bs_env"}, fn ->
        assert BillionSend.client(api_key: "").api_key == "bs_env"
        assert BillionSend.client(api_key: " \n").api_key == "bs_env"
      end)

      with_env(%{"BILLIONSEND_API_KEY" => nil}, fn ->
        assert BillionSend.client(api_key: " ").api_key == nil
        assert BillionSend.client().api_key == nil
      end)
    end

    test "a key with a character a header cannot carry is refused before sending, without printing it" do
      {client, mock} = client(api_key: "bs_secret_key\nX-Injected: 1")

      error = assert_raise ArgumentError, fn -> BillionSend.Domains.list(client) end
      assert error.message =~ "Authorization"
      refute error.message =~ "bs_secret_key"
      assert Mock.calls(mock) == []
    end
  end

  describe "the base URL" do
    test "explicit, then the environment, then the public API" do
      with_env(%{"BILLIONSEND_BASE_URL" => "https://env.example.test"}, fn ->
        assert BillionSend.client(base_url: "https://given.example.test").base_url ==
                 "https://given.example.test"

        assert BillionSend.client().base_url == "https://env.example.test"
        assert BillionSend.client(base_url: "").base_url == "https://api.billionsend.com"
      end)

      with_env(%{"BILLIONSEND_BASE_URL" => ""}, fn ->
        assert BillionSend.client().base_url == "https://api.billionsend.com"
      end)
    end

    test "trailing slashes are dropped and a path prefix is kept" do
      assert BillionSend.client(base_url: "https://x.test/v1///").base_url == "https://x.test/v1"
    end
  end

  describe "headers" do
    test "the user agent names this SDK and its version" do
      {client, mock} = client()
      {:ok, _} = BillionSend.Domains.list(client)

      assert Call.header(List.last(Mock.calls(mock)), "user-agent") =~
               ~r{\Abillionsend-elixir/\d+\.\d+\.\d+\z}
    end

    test "a default header replaces one of the SDK's under any spelling" do
      {client, mock} = client(default_headers: [{"USER-agent", "mine/1"}, {:"x-tag", 7}])
      {:ok, _} = BillionSend.Domains.list(client)
      call = List.last(Mock.calls(mock))

      assert for({k, v} <- call.request.headers, String.downcase(k) == "user-agent", do: v) == [
               "mine/1"
             ]

      assert Call.header(call, "x-tag") == "7"
    end

    test "a header a line break or a non-ASCII character cannot ride in is refused before sending" do
      {client, mock} = client()

      for {name, value} <- [
            {"x-a", "one\r\nX-Evil: 1"},
            {"x-a", "café"},
            {"bad name", "v"},
            {"x-a", <<0>>}
          ] do
        assert_raise ArgumentError, ~r/header/, fn ->
          BillionSend.Domains.list(client, extra_headers: [{name, value}])
        end
      end

      assert Mock.calls(mock) == []
    end

    test "an idempotency key that is not printable ASCII is refused, not retried as a network failure" do
      {client, mock} = client()
      email = %{from: "a@acme.com", to: ["b@example.com"], subject: "s", text: "t"}

      error =
        assert_raise ArgumentError, fn ->
          BillionSend.Emails.send(client, email, idempotency_key: "welcome/订单-1")
        end

      assert error.message =~ "Idempotency-Key"
      assert Mock.calls(mock) == []
      assert sleeps() == []

      {:ok, _} = BillionSend.Emails.send(client, email, idempotency_key: "welcome/order 1:#42")
      assert Call.header(List.last(Mock.calls(mock)), "idempotency-key") == "welcome/order 1:#42"
    end
  end

  describe "timeouts" do
    test "the client's timeout and a call's own reach the transport" do
      {client, mock} = client(timeout: 1_234)
      {:ok, _} = BillionSend.Domains.list(client)
      {:ok, _} = BillionSend.Domains.list(client, timeout: 99)
      assert Enum.map(Mock.calls(mock), & &1.request.timeout) == [1_234, 99]
    end

    test "anything but a positive number of milliseconds is refused" do
      for bad <- [0, -1, 1.5, "5", nil, :infinity] do
        assert_raise ArgumentError, ~r/timeout/, fn ->
          BillionSend.client(api_key: "k", timeout: bad)
        end
      end

      {client, mock} = client()

      assert_raise ArgumentError, ~r/timeout/, fn ->
        BillionSend.Domains.list(client, timeout: "5")
      end

      assert_raise ArgumentError, ~r/timeout/, fn ->
        BillionSend.Domains.list(client, timeout: 0)
      end

      assert Mock.calls(mock) == []
    end
  end

  describe "path parameters" do
    test "an id that is nil or empty is refused instead of calling the collection" do
      {client, mock} = client()

      for id <- [nil, ""] do
        assert_raise ArgumentError, ~r/path parameter/, fn ->
          BillionSend.Domains.get(client, id)
        end

        assert_raise ArgumentError, ~r/path parameter/, fn ->
          BillionSend.Domains.Claims.get(client, id)
        end
      end

      assert Mock.calls(mock) == []
    end

    test "an id that is a dot segment is refused: it would be folded into another route" do
      {client, mock} = client()

      for id <- [".", ".."] do
        assert_raise ArgumentError, ~r/dot segment/, fn -> BillionSend.Domains.get(client, id) end
      end

      # Dots inside an id are fine.
      {:ok, _} = BillionSend.Inboxes.get(client, "a.b..c@example.com")
      {:ok, _} = BillionSend.Inboxes.get(client, "...")
      assert length(Mock.calls(mock)) == 2
    end

    test "every reserved or non-ASCII character is percent-encoded, @ is kept" do
      {client, mock} = client()
      {:ok, _} = BillionSend.Inboxes.get(client, "a+b@x.com é/?#%")

      assert URI.parse(List.last(Mock.calls(mock)).request.url).path ==
               "/inboxes/a%2Bb@x.com%20%C3%A9%2F%3F%23%25"

      assert BillionSend.Client.encode_path(:atom_id) == "atom_id"
      assert BillionSend.Client.encode_path(42) == "42"
      assert BillionSend.Client.encode_path("-._~") == "-._~"
    end
  end

  describe "query" do
    test "text is percent-encoded, lists comma-separated, booleans spelled out, unset values left out" do
      assert BillionSend.Client.encode_query(a: "x y&z=1", b: [1, "two", true], c: false, d: nil) ==
               "a=x%20y%26z%3D1&b=1%2Ctwo%2Ctrue&c=false"

      assert BillionSend.Client.encode_query(%{"é" => "ü"}) == "%C3%A9=%C3%BC"
      assert BillionSend.Client.encode_query([]) == ""
      # An empty list is no filter: it is not sent at all.
      assert BillionSend.Client.encode_query(l: [], m: ["a"]) == "m=a"
      assert BillionSend.Client.encode_query(l: []) == ""
    end
  end

  describe "request bodies" do
    test "a keyword list is an object, at any depth; structs and plain lists are left alone" do
      {client, mock} = client()

      {:ok, _} =
        BillionSend.Emails.send(client,
          from: "Acme <hello@acme.dev>",
          to: ["b@example.com"],
          subject: "s",
          text: "t",
          headers: [{"X-Entity-Ref-ID", "1"}] |> Map.new(),
          tags: [[name: "a", value: "b"]],
          scheduled_at: ~U[2026-01-01 00:00:00Z]
        )

      assert List.last(Mock.calls(mock)).body == %{
               "from" => "Acme <hello@acme.dev>",
               "to" => ["b@example.com"],
               "subject" => "s",
               "text" => "t",
               "headers" => %{"X-Entity-Ref-ID" => "1"},
               "tags" => [%{"name" => "a", "value" => "b"}],
               "scheduled_at" => "2026-01-01T00:00:00Z"
             }
    end

    test "non-ASCII text goes out as UTF-8 and null stays null" do
      {client, mock} = client()
      change = %{first_name: "J\u00fcrgen \u4e16\u754c", last_name: nil, properties: %{plan: nil}}
      {:ok, _} = BillionSend.Contacts.update(client, id(), change)
      body = List.last(Mock.calls(mock)).request.body
      assert body =~ "J\u00fcrgen \u4e16\u754c"

      assert JSON.decode!(body) == %{
               "first_name" => "J\u00fcrgen \u4e16\u754c",
               "last_name" => nil,
               "properties" => %{"plan" => nil}
             }
    end
  end

  describe "Client.request/4" do
    test "sends anything the functions do not cover, with the options the functions use" do
      {client, mock} = client()

      assert {:ok, _} =
               BillionSend.Client.request(client, "GET", "/domains",
                 query: %{limit: 2},
                 extra_headers: [{"X-Trace", "t"}],
                 timeout: 5_000
               )

      call = List.last(Mock.calls(mock))
      assert call.query == %{"limit" => ["2"]}
      assert Call.header(call, "x-trace") == "t"
      assert call.request.timeout == 5_000
    end

    test "a key of its own, or one made up on request" do
      {client, mock} = client()
      body = %{from: "a@acme.com", to: ["b@example.com"], subject: "s", text: "t"}

      {:ok, _} =
        BillionSend.Client.request(client, "POST", "/emails", body: body, idempotency_key: "mine")

      {:ok, _} =
        BillionSend.Client.request(client, "POST", "/emails",
          body: body,
          auto_idempotency_key: true
        )

      [first, second] = Mock.calls(mock)
      assert Call.header(first, "idempotency-key") == "mine"
      assert Call.header(second, "idempotency-key") =~ ~r/\A[0-9a-f-]{36}\z/
    end

    test "an unauthenticated request carries no key" do
      {client, mock} = client(api_key: nil)

      {:ok, _} =
        BillionSend.Client.request(client, "POST", "/agent/signup",
          auth: false,
          body: %{human_email: "o@example.com", name: "Scout"}
        )

      assert Call.header(List.last(Mock.calls(mock)), "authorization") == nil
    end
  end

  test "an answer that is empty is nil, and unknown or null fields come back untouched" do
    {client, mock} = client()

    Mock.respond(mock, "GET", "/domains/{id}", 200,
      body: "",
      headers: [{"content-type", "application/json"}]
    )

    assert {:ok, nil} = BillionSend.Domains.get(client, id())

    {_, _, schema} = Contract.Operation.success(Contract.operation("GET", "/domains/{id}"))

    domain =
      schema
      |> Contract.example()
      |> Map.merge(%{"brand_new_field" => %{"nested" => [1, nil]}, "tracking_error" => nil})

    Mock.respond(mock, "GET", "/domains/{id}", 200, json: domain)
    assert {:ok, ^domain} = BillionSend.Domains.get(client, id())
  end

  describe "the shorter forms" do
    test "a client with no options, and Client.request with no options" do
      assert %BillionSend.Client{base_url: "https://api.billionsend.com"} = BillionSend.Client.new()
      {client, mock} = client()
      assert {:ok, _} = BillionSend.Client.request(client, "GET", "/domains")
      assert [%{query: query}] = Mock.calls(mock)
      assert query == %{}
    end

    test "a required option that is missing, and options that are not a keyword list, are refused" do
      {client, mock} = client()

      assert_raise ArgumentError, ~r/missing required options \[:type\]/, fn ->
        BillionSend.Broadcasts.recipients(client, id())
      end

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        BillionSend.Domains.list(client, [1, 2])
      end

      assert Mock.calls(mock) == []
    end

    test "the error fields every error is built from" do
      fields = BillionSend.Errors.fields()

      assert Keyword.keys(fields) == [
               :message,
               :name,
               :status_code,
               :request_id,
               :retry_after,
               :response
             ]

      assert fields[:name] == "application_error"
    end
  end
end
