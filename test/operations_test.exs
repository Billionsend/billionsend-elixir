defmodule BillionSend.OperationsTest do
  @moduledoc """
  Every operation of the contract, one test group each, through the contract
  mock (`test/support/contract.ex`): the request the SDK sends is compared with
  what `BillionSend.Test.Requests` works out from the OpenAPI document, the answer
  is the document's own example (or one built from its schema) and must come back
  unchanged, and every kind of failure the operation can meet is followed.
  """
  use ExUnit.Case, async: true

  import BillionSend.Test.Helpers
  alias BillionSend.Test.{Contract, Mock, Requests}
  alias BillionSend.Test.Contract.Operation
  alias BillionSend.Test.Mock.Call

  # (a function: a regex in a module attribute does not survive every OTP release)
  defp uuid4, do: ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @errors %{
    400 => BillionSend.ValidationError,
    403 => BillionSend.PermissionDeniedError,
    404 => BillionSend.NotFoundError,
    409 => BillionSend.ConflictError,
    410 => BillionSend.Error,
    422 => BillionSend.ValidationError
  }

  # The operation, by the two things that name it (a Regex does not survive a macro).
  defp op({method, path}), do: Contract.operation(method, path)

  defp roundtrip(value), do: value |> JSON.encode!() |> JSON.decode!()

  # The answer the API gives for the operation, and the SDK's answer for it.
  defp queue_answer(mock, op, mutate \\ & &1) do
    {status, media, schema} = Operation.success(op)

    cond do
      media == "text/event-stream" ->
        Mock.respond(mock, op.method, op.path, status,
          headers: [{"content-type", media}],
          chunks: []
        )

        :stream

      schema == nil ->
        Mock.respond(mock, op.method, op.path, status)
        {:ok, nil}

      true ->
        json = mutate.(Contract.example(schema, true))
        Mock.respond(mock, op.method, op.path, status, json: json)
        {:ok, roundtrip(json)}
    end
  end

  defp assert_request(%Call{} = call, %Requests{} = r) do
    op = r.op
    uri = URI.parse(call.request.url)
    where = "#{op.method} #{op.path}"

    assert call.operation == op
    assert uri.path == r.path, "#{where}: path"
    assert call.query == r.query, "#{where}: query"
    assert call.body == r.wire_body, "#{where}: body"

    for {name, value} <- r.headers do
      assert Call.header(call, name) == value, "#{where}: header #{name}"
    end

    assert Call.header(call, "authorization") ==
             if(Operation.needs_auth?(op), do: "Bearer #{Contract.api_key()}"),
           "#{where}: authorization"

    assert Call.header(call, "user-agent") == "billionsend-elixir/" <> BillionSend.version()

    if Operation.idempotency_key?(op) do
      key = Call.header(call, "idempotency-key")
      if r.key, do: assert(key == r.key), else: assert(key =~ uuid4(), "#{where}: key #{key}")
    end
  end

  defp assert_answer(result, :stream) do
    assert {:ok, stream} = result
    assert Enum.take(stream, 0) == []
  end

  defp assert_answer(result, expected), do: assert(result == expected)

  for op <- Contract.operations() do
    method = op.method
    path = op.path
    id = Operation.id(op)

    describe id do
      test "sends the request the document describes and returns the answer as it came" do
        op = op({unquote(method), unquote(path)})

        for mode <- [:minimal, :full] do
          {client, mock} = client()
          r = Requests.build(op, mode)
          expected = queue_answer(mock, op)

          assert_answer(Requests.call(client, r), expected)
          assert [call] = Mock.calls(mock)
          assert_request(call, r)
        end
      end

      test "works the same through the default transport, on a real socket" do
        op = op({unquote(method), unquote(path)})

        for mode <- [:minimal, :full] do
          mock = Mock.start()
          server = BillionSend.Test.ContractServer.start(mock)

          try do
            client = BillionSend.client(api_key: Contract.api_key(), base_url: server.base_url)
            r = Requests.build(op, mode)
            expected = queue_answer(mock, op)

            assert_answer(Requests.call(client, r), expected)
            assert Mock.violations(mock) == []
            assert [call] = Mock.calls(mock)
            assert_request(call, r)
          after
            BillionSend.Test.ContractServer.stop(server)
          end
        end
      end

      test "its ! twin returns the answer, or raises the error" do
        op = op({unquote(method), unquote(path)})
        {client, mock} = client()
        r = Requests.build(op, :minimal)

        case queue_answer(mock, op) do
          :stream -> assert Enum.take(Requests.call(client, r, true), 0) == []
          {:ok, answer} -> assert Requests.call(client, r, true) == answer
        end

        status = Requests.error_status(op)
        Mock.error(mock, op.method, op.path, status, "sdk_test_error", "Something is wrong")
        module = Map.fetch!(@errors, status)
        assert_raise module, fn -> Requests.call(client, r, true) end
      end

      test "called with its body alone, and its ! twin the same" do
        op = op({unquote(method), unquote(path)})

        if r = Requests.body_only(op) do
          for bang <- [false, true] do
            {client, mock} = client()
            expected = queue_answer(mock, op)
            result = Requests.call(client, r, bang)

            case {bang, expected} do
              {true, {:ok, answer}} -> assert result == answer
              {true, :stream} -> assert Enum.take(result, 0) == []
              _ -> assert_answer(result, expected)
            end

            assert [call] = Mock.calls(mock)
            assert_request(call, r)
          end
        end
      end

      test "every error the operation declares comes back as its error, whole" do
        op = op({unquote(method), unquote(path)})
        {client, mock} = client()
        r = Requests.build(op, :minimal)
        status = Requests.error_status(op)
        module = Map.fetch!(@errors, status)

        Mock.error(mock, op.method, op.path, status, "sdk_test_error", "Something is wrong",
          headers: [{"x-request-id", "req_#{unquote(id)}"}]
        )

        assert {:error, %{__struct__: ^module} = error} = Requests.call(client, r)
        assert error.status_code == status
        assert error.name == "sdk_test_error"
        assert error.message == "Something is wrong"
        assert error.request_id == "req_#{unquote(id)}"

        assert JSON.decode!(error.response.body) == %{
                 "statusCode" => status,
                 "name" => "sdk_test_error",
                 "message" => "Something is wrong"
               }

        assert Exception.message(error) == "#{status} sdk_test_error: Something is wrong"
        assert length(Mock.calls(mock)) == 1
      end

      test "a rate limit asking for more than a minute is returned, not waited out" do
        op = op({unquote(method), unquote(path)})
        {client, mock} = client()
        r = Requests.build(op, :minimal)

        Mock.error(mock, op.method, op.path, 429, "rate_limit_exceeded", "Slow down",
          headers: [{"retry-after", "61"}]
        )

        assert {:error, %BillionSend.RateLimitError{retry_after: 61.0, status_code: 429}} =
                 Requests.call(client, r)

        assert length(Mock.calls(mock)) == 1
        assert sleeps() == []
      end
    end

    if not Requests.stream?(op) do
      describe "#{id} retries" do
        test "a 503 and a lost connection are retried exactly when repeating is safe" do
          op = op({unquote(method), unquote(path)})

          safe? =
            (op.method in ~w(GET PUT DELETE) and not Operation.upload?(op)) or
              Operation.idempotency_key?(op)

          for failure <- [:status, :connection] do
            {client, mock} = client()
            r = Requests.build(op, :minimal)

            case failure do
              :status ->
                Mock.error(mock, op.method, op.path, 503, "unavailable", "Try later")

              :connection ->
                Mock.fail(mock, op.method, op.path, %BillionSend.APIConnectionError{
                  message: "reset"
                })
            end

            expected = queue_answer(mock, op)
            result = Requests.call(client, r)
            calls = Mock.calls(mock)

            if safe? do
              assert result == expected
              assert length(calls) == 2
              assert length(sleeps()) == 1
              keys = Enum.map(calls, &Call.header(&1, "idempotency-key"))
              assert length(Enum.uniq(keys)) == 1
            else
              assert {:error, _} = result
              assert length(calls) == 1
              assert sleeps() == []
            end
          end
        end

        test "a 429 is retried for every method, after its Retry-After: it was refused before anything was written" do
          op = op({unquote(method), unquote(path)})
          {client, mock} = client()
          r = Requests.build(op, :minimal)

          Mock.error(mock, op.method, op.path, 429, "rate_limit_exceeded", "Slow down",
            headers: [{"retry-after", "3"}]
          )

          expected = queue_answer(mock, op)
          assert Requests.call(client, r) == expected
          assert length(Mock.calls(mock)) == 2
          assert sleeps() == [3000]
        end

        test "an idempotent send waits out a first attempt that is still running" do
          op = op({unquote(method), unquote(path)})

          if Operation.idempotency_key?(op) do
            {client, mock} = client()
            r = Requests.build(op, :minimal)

            Mock.error(
              mock,
              op.method,
              op.path,
              409,
              "concurrent_idempotent_requests",
              "Still running"
            )

            expected = queue_answer(mock, op)
            assert Requests.call(client, r) == expected
            assert length(Mock.calls(mock)) == 2
          end
        end
      end
    end

    if Enum.any?(Operation.params(op, "query") ++ Operation.params(op, "header"), & &1["required"]) do
      describe "#{id} required options" do
        test "refuses to be called without them, before anything is sent" do
          op = op({unquote(method), unquote(path)})
          {client, mock} = client()
          r = %{Requests.build(op, :minimal) | opts: []}

          for bang <- [false, true] do
            assert_raise ArgumentError, ~r/missing required options/, fn ->
              Requests.call(client, r, bang)
            end
          end

          if Requests.paged?(op) do
            assert_raise ArgumentError, ~r/missing required options/, fn ->
              client |> Requests.call_all(r) |> Enum.to_list()
            end
          end

          assert Mock.calls(mock) == []
        end
      end
    end

    if Requests.paged?(op) do
      describe "#{id} pages" do
        test "its _all stream walks every page by the last id" do
          op = op({unquote(method), unquote(path)})
          {client, mock} = client()
          {status, _, schema} = Operation.success(op)
          r = Requests.build(op, :minimal)

          r =
            if Enum.any?(Operation.params(op, "query"), &(&1["name"] == "limit")),
              do: %{
                r
                | opts: Keyword.put(r.opts, :limit, 2),
                  query: Map.put(r.query, "limit", ["2"])
              },
              else: r

          page = Contract.example(schema, true)
          first = %{page | "has_more" => true}
          second = %{page | "has_more" => false}
          Mock.respond(mock, op.method, op.path, status, json: first)
          Mock.respond(mock, op.method, op.path, status, json: second)

          items = Enum.to_list(Requests.call_all(client, r))
          assert items == roundtrip(first["data"] ++ second["data"])
          assert [one, two] = Mock.calls(mock)
          assert one.query == r.query
          assert two.query == Map.put(r.query, "after", [List.last(first["data"])["id"]])
        end

        test "its _all stream with no options at all, where the operation allows that" do
          op = op({unquote(method), unquote(path)})
          r = Requests.build(op, :minimal)

          if r.opts == [] do
            {client, mock} = client()
            {status, _, schema} = Operation.success(op)
            page = %{Contract.example(schema, true) | "has_more" => false}
            Mock.respond(mock, op.method, op.path, status, json: page)
            assert Enum.to_list(Requests.call_all(client, r)) == roundtrip(page["data"])
            assert [call] = Mock.calls(mock)
            assert call.query == %{}
          end
        end
      end
    end
  end

  test "every function of the resource modules is an operation, its ! twin or its _all stream" do
    ops = Contract.operations()
    expected = MapSet.new(ops, &Requests.target/1)
    paged = MapSet.new(for op <- ops, Requests.paged?(op), do: Requests.target(op))

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

    # Every cursor list has its stream.
    for {module, name} <- paged do
      all = String.to_atom("#{name}_all")
      assert Enum.any?(module.__info__(:functions), fn {n, _} -> n == all end)
    end
  end

  test "only the sending operations carry an Idempotency-Key header" do
    keyed = for op <- Contract.operations(), Operation.idempotency_key?(op), do: Operation.id(op)

    assert Enum.sort(keyed) ==
             Enum.sort(~w(emails.send emails.batch emails.receiving.reply emails.receiving.forward
                          inboxes.send inboxes.threads.emails.reply inboxes.threads.emails.forward
                          inboxes.drafts.send events.send))
  end
end
