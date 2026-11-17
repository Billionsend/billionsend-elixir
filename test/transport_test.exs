defmodule BillionSend.TransportTest do
  @moduledoc """
  The :httpc transport against a real socket: requests, answers, streamed
  bodies read as they arrive, and failures without an answer.
  """
  use ExUnit.Case, async: false

  defp serve(handler, fun) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
    {:ok, port} = :inet.port(listen)
    parent = self()

    server =
      spawn_link(fn ->
        accept = fn accept ->
          case :gen_tcp.accept(listen) do
            {:ok, socket} ->
              {head, body} = read_request(socket, "")
              send(parent, {:request, head, body})
              handler.(socket)
              :gen_tcp.close(socket)
              accept.(accept)

            {:error, _} ->
              :ok
          end
        end

        accept.(accept)
      end)

    try do
      fun.("http://127.0.0.1:#{port}")
    after
      :gen_tcp.close(listen)
      Process.unlink(server)
      Process.exit(server, :kill)
    end
  end

  defp read_request(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        length =
          case Regex.run(~r/content-length: (\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            nil -> 0
          end

        body =
          if byte_size(body) < length,
            do: body <> recv(socket, length - byte_size(body)),
            else: body

        {head, body}

      _ ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, acc <> data)
    end
  end

  defp recv(socket, n) do
    {:ok, data} = :gen_tcp.recv(socket, n, 5_000)
    data
  end

  defp client(url, opts \\ []),
    do: BillionSend.client(Keyword.merge([api_key: "bs_socket_test", base_url: url], opts))

  test "a JSON request and answer" do
    body = ~s({"object":"list","has_more":false,"data":[]})

    serve(
      fn s ->
        :gen_tcp.send(
          s,
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
        )
      end,
      fn url ->
        assert {:ok, %{"object" => "list", "data" => []}} =
                 BillionSend.Domains.list(client(url), limit: 3)

        assert_received {:request, head, ""}
        assert head =~ "GET /domains?limit=3 HTTP/1.1"
        assert head =~ ~r/authorization: Bearer bs_socket_test/i
        assert head =~ ~r/connection: close/i
      end
    )
  end

  test "an error answer keeps the request id; a send carries its key" do
    body = ~s({"statusCode":422,"name":"validation_error","message":"Invalid from"})

    serve(
      fn s ->
        :gen_tcp.send(
          s,
          "HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: application/json\r\nX-Request-Id: req_9\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
        )
      end,
      fn url ->
        email = %{from: "x", to: ["y@example.com"], subject: "s", text: "t"}

        assert {:error, %BillionSend.ValidationError{request_id: "req_9", message: "Invalid from"}} =
                 BillionSend.Emails.send(client(url), email)

        assert_received {:request, head, sent}

        assert JSON.decode!(sent) == %{
                 "from" => "x",
                 "to" => ["y@example.com"],
                 "subject" => "s",
                 "text" => "t"
               }

        assert head =~ ~r/idempotency-key: [0-9a-fA-F]{8}-/i
      end
    )
  end

  test "an event stream is read as it arrives" do
    parent = self()

    serve(
      fn s ->
        :gen_tcp.send(
          s,
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
        )

        first =
          ~s(id: 1\nevent: inbox.email.received\ndata: {"type":"inbox.email.received","inbox_id":"i","data":{}}\n\n)

        :gen_tcp.send(s, Integer.to_string(byte_size(first), 16) <> "\r\n" <> first <> "\r\n")
        send(parent, {:server, self()})

        receive do
          :release -> :gen_tcp.send(s, "0\r\n\r\n")
        after
          5_000 -> :ok
        end
      end,
      fn url ->
        {:ok, stream} = BillionSend.Inboxes.Events.stream(client(url, sleep: fn _ -> :ok end))
        assert [%BillionSend.InboxStreamEvent{id: "1"}] = Enum.take(stream, 1)
        assert_received {:request, head, _}
        assert head =~ ~r/accept: text\/event-stream/i
        assert_receive {:server, pid}
        send(pid, :release)
      end
    )
  end

  test "no answer is a connection error, retried for a GET" do
    serve(fn s -> :gen_tcp.close(s) end, fn url ->
      client = client(url, max_retries: 1, sleep: fn _ -> :ok end)
      assert {:error, %BillionSend.APIConnectionError{}} = BillionSend.Domains.list(client)
      assert_received {:request, _, _}
      assert_received {:request, _, _}
    end)
  end

  test "a slow answer times out" do
    serve(fn _ -> Process.sleep(2_000) end, fn url ->
      assert {:error, %BillionSend.APITimeoutError{}} =
               BillionSend.Domains.list(client(url, timeout: 300, max_retries: 0))
    end)
  end
end
