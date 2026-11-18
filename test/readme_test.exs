defmodule BillionSend.ReadmeTest do
  @moduledoc """
  Every `elixir` code block of the README is run as written, through a client
  built the way the README builds one (`BILLIONSEND_API_KEY`,
  `BILLIONSEND_BASE_URL`), against a local server that answers by the contract
  (`BillionSend.Test.ContractServer`): the default transport, real sockets, and
  every request checked against the OpenAPI document.

  A block the README has that is not listed here fails the test, and so does a
  listed block the README no longer has: the README cannot drift from the code.
  Only what the README leaves to the reader is supplied (`user`, `message`,
  `saved_position`, `require Logger`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias BillionSend.Test.{Contract, ContractServer, Mock, Requests}
  alias BillionSend.Test.Contract.Operation
  alias BillionSend.Test.Mock.Call

  @readme Path.expand("../README.md", __DIR__)
  @external_resource @readme
  @blocks Regex.scan(~r/```elixir\n(.*?)```/s, File.read!(@readme), capture: :all_but_first)
          |> Enum.map(fn [text] -> text end)

  # The first line of every block the tests below run, in README order.
  @handled [
    "def deps do",
    "client = BillionSend.client()  # reads BILLIONSEND_API_KEY",
    "{:ok, signup} = BillionSend.Agent.signup(BillionSend.client(), %{human_email: \"owner@example.com\", name: \"Scout\"})",
    "BillionSend.Emails.send(client, message, idempotency_key: \"welcome/\#{user.id}\")",
    "alias BillionSend.{Inboxes, InboxStreamEvent}",
    "{:ok, events} = BillionSend.Inboxes.Events.stream(client, last_event_id: saved_position)",
    "# Phoenix: keep the raw body (a Plug.Parsers :body_reader that stores it in conn.assigns)",
    "{:ok, upload} =",
    "client",
    "case BillionSend.Domains.get(client, \"6a1f1d38-3c55-4a4e-9a57-0f2b3c4d5e6f\") do"
  ]

  defp block(first_line) do
    Enum.find(@blocks, &(hd(String.split(&1, "\n")) == first_line)) ||
      flunk("the README has no block starting with #{inspect(first_line)}")
  end

  setup do
    mock = Mock.start()
    server = ContractServer.start(mock)
    saved = Map.new(~w(BILLIONSEND_API_KEY BILLIONSEND_BASE_URL), &{&1, System.get_env(&1)})
    System.put_env("BILLIONSEND_API_KEY", Contract.api_key())
    System.put_env("BILLIONSEND_BASE_URL", server.base_url)

    on_exit(fn ->
      ContractServer.stop(server)
      Enum.each(saved, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
    end)

    {:ok, mock: mock, client: BillionSend.client()}
  end

  # What the contract says the operation answers, with changes; queued for the next call.
  defp answer(mock, method, path, change \\ & &1) do
    op = Contract.operation(method, path)
    {status, _, schema} = Operation.success(op)
    json = change.(Contract.example(schema))
    Mock.respond(mock, method, path, status, json: json)
    json
  end

  defp calls(mock, method, path),
    do:
      Enum.filter(Mock.calls(mock), &(&1.operation.method == method and &1.operation.path == path))

  defp run(text, binding \\ []), do: Code.eval_string(text, binding)

  test "the README has no elixir block this test does not run, and none that is gone" do
    first_lines = Enum.map(@blocks, &hd(String.split(&1, "\n")))
    assert first_lines == @handled
  end

  test "the install snippet asks for a version this package satisfies" do
    [_, requirement] = Regex.run(~r/\{:billionsend, "([^"]+)"\}/, block("def deps do"))
    assert Version.match?(BillionSend.version(), requirement)
  end

  test "quick start sends the email it shows and prints its id", %{mock: mock} do
    %{"id" => id} = answer(mock, "POST", "/emails")

    output =
      capture_io(fn -> run(block("client = BillionSend.client()  # reads BILLIONSEND_API_KEY")) end)

    assert output == id <> "\n"
    assert [call] = Mock.calls(mock)

    assert %{"from" => "Acme <hello@acme.dev>", "subject" => "Welcome to Acme", "to" => [to]} =
             call.body

    assert to =~ ~r/\A[^@\s]+@[^@\s]+\z/
    assert call.body["html"] == "<p>Thanks for signing up!</p>"
    assert Mock.violations(mock) == []
  end

  test "an agent signs up without a key and then asks its own status", %{mock: mock} do
    answer(mock, "POST", "/agent/signup", &Map.put(&1, "api_key", Contract.api_key()))
    %{"status" => status} = answer(mock, "GET", "/agent/status")

    {_, binding} = run(block(Enum.at(@handled, 2)))

    assert binding[:status] == status
    assert binding[:client].api_key == Contract.api_key()
    [signup, status_call] = Mock.calls(mock)
    assert Call.header(signup, "authorization") == nil
    assert Call.header(status_call, "authorization") == "Bearer " <> Contract.api_key()
    assert signup.body == %{"human_email" => "owner@example.com", "name" => "Scout"}
    assert Mock.violations(mock) == []
  end

  test "a send with a key of its own sends that key", %{mock: mock, client: client} do
    answer(mock, "POST", "/emails")

    message = %{
      from: "Acme <hello@acme.dev>",
      to: ["success@simulator.amazonses.com"],
      subject: "s",
      text: "t"
    }

    run(block("BillionSend.Emails.send(client, message, idempotency_key: \"welcome/\#{user.id}\")"),
      client: client,
      message: message,
      user: %{id: 42}
    )

    assert [call] = Mock.calls(mock)
    assert Call.header(call, "idempotency-key") == "welcome/42"
  end

  test "an agent answers the mail in its inbox", %{mock: mock} do
    inbox = answer(mock, "POST", "/inboxes", &Map.put(&1, "id", Requests.uuid(1)))
    thread_id = Requests.uuid(2)
    email_id = Requests.uuid(3)

    data = %{
      "type" => "inbox.email.received",
      "created_at" => "2026-11-19T00:00:00.000Z",
      "inbox_id" => inbox["id"],
      "data" => %{"thread_id" => thread_id, "email_id" => email_id}
    }

    Mock.respond(mock, "GET", "/inboxes/{inbox_id}/events", 200,
      headers: [{"content-type", "text/event-stream"}],
      chunks: [
        ": keepalive\n\n",
        "id: 10\nevent: inbox.email.received\ndata: #{JSON.encode!(data)}\n\n"
      ],
      error: :hold
    )

    answer(mock, "GET", "/inboxes/{inbox_id}/threads/{thread_id}/emails/{email_id}", fn example ->
      Map.merge(example, %{"direction" => "inbound", "extracted_text" => "Where is my order?"})
    end)

    answer(mock, "POST", "/inboxes/{inbox_id}/threads/{thread_id}/emails/{email_id}/reply")

    task = Task.async(fn -> run(block("alias BillionSend.{Inboxes, InboxStreamEvent}")) end)

    reply =
      wait_for(mock, "POST", "/inboxes/{inbox_id}/threads/{thread_id}/emails/{email_id}/reply")

    Task.shutdown(task, :brutal_kill)

    assert reply.path_params == %{
             "inbox_id" => inbox["id"],
             "thread_id" => thread_id,
             "email_id" => email_id
           }

    assert reply.body == %{"text" => "Thanks, we got your message:\n\n> Where is my order?"}

    [create] = calls(mock, "POST", "/inboxes")
    assert create.body == %{"username" => "support", "kind" => "agent"}
    [stream] = calls(mock, "GET", "/inboxes/{inbox_id}/events")
    assert stream.query == %{"types" => ["inbox.email.received"]}
    assert Mock.violations(mock) == []
  end

  defp wait_for(mock, method, path, tries \\ 100) do
    case calls(mock, method, path) do
      [call | _] ->
        call

      [] when tries > 0 ->
        Process.sleep(50)
        wait_for(mock, method, path, tries - 1)

      [] ->
        flunk(
          "#{method} #{path} was never called; calls: #{inspect(Enum.map(Mock.calls(mock), &Call.key/1))}"
        )
    end
  end

  test "resuming a stream from a saved position sends it", %{mock: mock, client: client} do
    Mock.respond(mock, "GET", "/inboxes/events", 200,
      headers: [{"content-type", "text/event-stream"}],
      chunks: []
    )

    {_, binding} =
      run(
        block(
          "{:ok, events} = BillionSend.Inboxes.Events.stream(client, last_event_id: saved_position)"
        ),
        client: client,
        saved_position: "42"
      )

    assert Enum.take(binding[:events], 0) == []
    assert [call] = Mock.calls(mock)
    assert Call.header(call, "last-event-id") == "42"
  end

  describe "the Phoenix controller" do
    @secret "whsec_" <> Base.encode64(String.duplicate("s", 32))

    setup do
      name = Module.concat(__MODULE__, "Controller#{System.unique_integer([:positive])}")

      source = """
      defmodule #{inspect(name)} do
        def webhook_secret, do: #{inspect(@secret)}
        def mark_bounced(id), do: send(self(), {:bounced, id})
        def send_resp(_conn, status, body), do: {status, body}

        #{block("# Phoenix: keep the raw body (a Plug.Parsers :body_reader that stores it in conn.assigns)")}
      end
      """

      [{^name, _}] = Code.compile_string(source)
      on_exit(fn -> :code.purge(name) && :code.delete(name) end)
      {:ok, controller: name}
    end

    defp delivery(body, secret \\ @secret) do
      "whsec_" <> encoded = secret
      key = Base.decode64!(encoded)
      id = "msg_1"
      timestamp = System.os_time(:second)
      mac = :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{body}")

      %{
        assigns: %{raw_body: body},
        req_headers: [
          {"content-type", "application/json"},
          {"webhook-id", id},
          {"webhook-timestamp", to_string(timestamp)},
          {"webhook-signature", "v1," <> Base.encode64(mac)}
        ]
      }
    end

    test "a bounce is marked, another event is acknowledged, a forged one is refused", %{
      controller: c
    } do
      bounced =
        ~s({"type":"email.bounced","created_at":"2026-11-19T00:00:00.000Z","data":{"email_id":"e1"}})

      other =
        ~s({"type":"email.delivered","created_at":"2026-11-19T00:00:00.000Z","data":{"email_id":"e2"}})

      assert c.create(delivery(bounced), %{}) == {204, ""}
      assert_received {:bounced, "e1"}

      assert c.create(delivery(other), %{}) == {204, ""}
      refute_received {:bounced, _}

      forged = delivery(bounced, "whsec_" <> Base.encode64(String.duplicate("x", 32)))
      assert c.create(forged, %{}) == {400, ""}
      refute_received {:bounced, _}
    end
  end

  test "a CSV import uploads the file and its column map, then reads the import", %{
    mock: mock,
    client: client
  } do
    tmp = Path.join(System.tmp_dir!(), "billionsend-readme-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    csv = "Email,First Name\r\nada@example.com,Ada\r\n"
    File.write!(Path.join(tmp, "contacts.csv"), csv)
    cwd = File.cwd!()

    import_id = Requests.uuid(7)

    Mock.respond(mock, "POST", "/contacts/imports", 200,
      json: %{"object" => "contact_import", "id" => import_id}
    )

    answer(mock, "GET", "/contacts/imports/{id}", &Map.put(&1, "id", import_id))

    try do
      File.cd!(tmp)
      {_, binding} = run(block("{:ok, upload} ="), client: client)
      assert binding[:upload]["id"] == import_id
    after
      File.cd!(cwd)
      File.rm_rf!(tmp)
    end

    [create, get] = Mock.calls(mock)
    assert create.body["file"] == csv
    assert create.body["on_conflict"] == "skip"

    assert JSON.decode!(create.body["column_map"]) == %{
             "email" => "Email",
             "first_name" => "First Name"
           }

    assert get.path_params == %{"id" => import_id}
    assert Mock.violations(mock) == []
  end

  test "paging: every contact once, and only the pages that are needed", %{
    mock: mock,
    client: client
  } do
    {_, _, schema} = Operation.success(Contract.operation("GET", "/contacts"))
    item = hd(Contract.example(schema)["data"])

    page = fn ids, more ->
      %{
        "object" => "list",
        "has_more" => more,
        "data" =>
          Enum.map(
            ids,
            &Map.merge(item, %{"id" => Requests.uuid(&1), "email" => "c#{&1}@example.com"})
          )
      }
    end

    Mock.respond(mock, "GET", "/contacts", 200, json: page.([1, 2], true))
    Mock.respond(mock, "GET", "/contacts", 200, json: page.([3], false))

    {_, _, domain_schema} = Operation.success(Contract.operation("GET", "/domains"))
    domain = hd(Contract.example(domain_schema)["data"])
    domains = Enum.map(1..12, &Map.put(domain, "id", Requests.uuid(&1)))

    Mock.respond(mock, "GET", "/domains", 200,
      json: %{"object" => "list", "has_more" => true, "data" => domains}
    )

    Mock.respond(mock, "GET", "/domains", 200,
      json: %{"object" => "list", "has_more" => false, "data" => domains}
    )

    output =
      capture_io(fn ->
        {_, binding} = run(block("client"), client: client)
        assert length(binding[:first_ten]) == 10
      end)

    assert output == "c1@example.com\nc2@example.com\nc3@example.com\n"
    assert length(calls(mock, "GET", "/contacts")) == 2
    assert length(calls(mock, "GET", "/domains")) == 1
    assert hd(calls(mock, "GET", "/contacts")).query == %{"limit" => ["100"]}
  end

  describe "the error handling block" do
    @preamble "require Logger\n"
    defp handle_errors(client),
      do:
        run(
          @preamble <>
            block(
              "case BillionSend.Domains.get(client, \"6a1f1d38-3c55-4a4e-9a57-0f2b3c4d5e6f\") do"
            ),
          client: client
        )
        |> elem(0)

    test "a missing domain is nil", %{mock: mock, client: client} do
      Mock.error(mock, "GET", "/domains/{id}", 404, "not_found", "Domain not found")
      assert handle_errors(client) == nil
    end

    test "a rate limit is the seconds to wait", %{mock: mock, client: client} do
      Mock.error(mock, "GET", "/domains/{id}", 429, "rate_limit_exceeded", "Slow down",
        headers: [{"retry-after", "61"}]
      )

      assert handle_errors(client) == {:retry_in, 61.0}
    end

    test "anything else is logged with its status, name, message and request id", %{
      mock: mock,
      client: client
    } do
      Mock.error(mock, "GET", "/domains/{id}", 401, "invalid_api_key", "API key is invalid",
        headers: [{"x-request-id", "req_42"}]
      )

      log = capture_log(fn -> assert handle_errors(client) == :ok end)
      assert log =~ "401 invalid_api_key: API key is invalid (req_42)"
    end

    test "a domain comes back as it is", %{mock: mock, client: client} do
      domain = answer(mock, "GET", "/domains/{id}")
      assert handle_errors(client) == domain
    end
  end

  describe "the calls the README names in its text" do
    test "a verification code is waited for", %{mock: mock, client: client} do
      answer(mock, "GET", "/inboxes/{inbox_id}/codes/latest")

      snippet =
        ~S'BillionSend.Inboxes.Codes.latest(client, inbox["id"], from: "example.com", wait: 30)'

      assert snippet =~ "wait: 30"
      assert {:ok, _} = run(snippet, client: client, inbox: %{"id" => Requests.uuid(1)}) |> elem(0)
      assert [call] = Mock.calls(mock)
      assert call.query == %{"from" => ["example.com"], "wait" => ["30"]}
    end

    test "the calling conventions the text shows", %{mock: mock, client: client} do
      binding = [client: client, domain_id: Requests.uuid(1), inbox_id: Requests.uuid(2)]
      readme = File.read!(@readme)

      for snippet <- [
            ~S'BillionSend.Domains.get(client, domain_id)',
            ~S'BillionSend.Domains.create(client, %{name: "acme.dev"})',
            ~S'BillionSend.Emails.list(client, limit: 50)',
            ~S'BillionSend.Domains.verify(client, domain_id)'
          ] do
        assert readme =~ snippet
        assert {{:ok, _}, _} = run(snippet, binding)
      end

      stream = ~S'BillionSend.Inboxes.Threads.list_all(client, inbox_id, read: false)'
      assert readme =~ stream
      assert {items, _} = run("Enum.take(#{stream}, 1)", binding)
      assert is_list(items)

      assert Mock.violations(mock) == []

      assert Enum.map(Mock.calls(mock), &Call.key/1) == [
               {"GET", "/domains/{id}"},
               {"POST", "/domains"},
               {"GET", "/emails"},
               {"POST", "/domains/{id}/verify"},
               {"GET", "/inboxes/{inbox_id}/threads"}
             ]
    end
  end
end
