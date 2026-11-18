defmodule BillionSend.WireTest do
  @moduledoc """
  The default transport against real sockets, plain and TLS: what goes on the
  wire, what comes back for every kind of answer (an empty one, an HTML page, a
  redirect, one cut short), and event streams in every framing a server may use.
  """
  use ExUnit.Case, async: false

  # The TLS alerts of the refusals are logged by :ssl.
  @moduletag :capture_log

  # --- servers ---------------------------------------------------------------------------

  # Serves one handler per connection, in order (the last one for every further
  # connection); each handler gets the socket after the request was read, and the
  # request is sent to the test as {:request, head, body}.
  defp serve(handlers, fun), do: serve(handlers, [], fun)

  defp serve(handlers, tls, fun) do
    handlers = List.wrap(handlers)
    {:ok, listen} = listen(tls)
    {:ok, port} = port(listen, tls)
    parent = self()
    server = spawn_link(fn -> accept(listen, tls, handlers, parent) end)

    try do
      fun.(port)
    after
      close(listen, tls)
      Process.unlink(server)
      Process.exit(server, :kill)
    end
  end

  defp listen([]),
    do: :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

  defp listen(tls),
    do: :ssl.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}] ++ tls)

  defp port(listen, []), do: :inet.port(listen)

  defp port(listen, _) do
    {:ok, {_, port}} = :ssl.sockname(listen)
    {:ok, port}
  end

  defp close(listen, []), do: :gen_tcp.close(listen)
  defp close(listen, _), do: :ssl.close(listen)

  defp accept(listen, tls, [handler | rest] = handlers, parent) do
    accepted = if tls == [], do: :gen_tcp.accept(listen), else: :ssl.transport_accept(listen)

    with {:ok, socket} <- accepted,
         {:ok, socket} <- handshake(socket, tls) do
      mod = if tls == [], do: :gen_tcp, else: :ssl

      try do
        {head, body} = read_request(mod, socket, "")
        send(parent, {:request, head, body})
        handler.({mod, socket})
      rescue
        _ -> :ok
      end

      mod.close(socket)
      accept(listen, tls, if(rest == [], do: handlers, else: rest), parent)
    else
      {:error, :closed} -> :ok
      {:error, _} -> accept(listen, tls, handlers, parent)
    end
  end

  defp handshake(socket, []), do: {:ok, socket}

  defp handshake(socket, _) do
    case :ssl.handshake(socket, 5_000) do
      {:ok, socket} -> {:ok, socket}
      {:error, _} = error -> error
    end
  end

  defp read_request(mod, socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        length =
          case Regex.run(~r/content-length: (\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            nil -> 0
          end

        {head, read_body(mod, socket, body, length)}

      _ ->
        {:ok, data} = mod.recv(socket, 0, 5_000)
        read_request(mod, socket, acc <> data)
    end
  end

  defp read_body(_mod, _socket, body, length) when byte_size(body) >= length, do: body

  defp read_body(mod, socket, body, length) do
    {:ok, data} = mod.recv(socket, 0, 5_000)
    read_body(mod, socket, body <> data, length)
  end

  defp send_all({mod, socket}, data), do: mod.send(socket, data)

  defp json({_, _} = s, body, status \\ "200 OK", extra \\ "") do
    send_all(
      s,
      "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n#{extra}Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
    )
  end

  defp client(port, opts \\ []) do
    BillionSend.client(
      Keyword.merge(
        [api_key: "bs_wire_test", base_url: "http://127.0.0.1:#{port}", sleep: fn _ -> :ok end],
        opts
      )
    )
  end

  defp event(id, name \\ "inbox.email.received") do
    data = JSON.encode!(%{"type" => name, "inbox_id" => "i", "data" => %{}})
    "id: #{id}\nevent: #{name}\ndata: #{data}\n\n"
  end

  defp chunk(text), do: Integer.to_string(byte_size(text), 16) <> "\r\n" <> text <> "\r\n"

  # --- requests --------------------------------------------------------------------------

  describe "what goes on the wire" do
    test "headers of a JSON request, and the body in UTF-8 with the length of its bytes" do
      serve(&json(&1, ~s({"id":"e1"})), fn port ->
        email = %{
          from: "a@acme.com",
          to: ["b@example.com"],
          subject: "h\u00e9llo \u4e16\u754c",
          text: "t"
        }

        assert {:ok, %{"id" => "e1"}} =
                 BillionSend.Emails.send(client(port), email, idempotency_key: "k-1")

        assert_received {:request, head, body}
        assert head =~ "POST /emails HTTP/1.1"
        assert head =~ ~r/content-type: application\/json\r\n/i
        assert head =~ ~r/content-length: #{byte_size(body)}(\r\n|\z)/i
        assert head =~ ~r/user-agent: billionsend-elixir\/\d+\.\d+\.\d+\r\n/i
        assert head =~ ~r/authorization: Bearer bs_wire_test(\r\n|\z)/i
        assert head =~ ~r/accept: application\/json\r\n/i
        assert head =~ ~r/idempotency-key: k-1(\r\n|\z)/i
        assert head =~ ~r/connection: close(\r\n|\z)/i
        assert JSON.decode!(body)["subject"] == "h\u00e9llo \u4e16\u754c"
      end)
    end

    test "PUT, PATCH and DELETE go out as themselves" do
      serve(&json(&1, "{}"), fn port ->
        c = client(port)
        assert {:ok, _} = BillionSend.Domains.update(c, "d1", %{open_tracking: true})
        assert {:ok, _} = BillionSend.Domains.delete(c, "d1")

        assert {:ok, _} =
                 BillionSend.Inboxes.Threads.Labels.set(c, "i1", "t1", %{
                   label_ids: ["00000000-0000-4000-8000-000000000001"]
                 })

        assert_received {:request, patch, _}
        assert_received {:request, delete, ""}
        assert_received {:request, put, _}
        assert patch =~ "PATCH /domains/d1 HTTP/1.1"
        assert delete =~ "DELETE /domains/d1 HTTP/1.1"
        assert put =~ "PUT /inboxes/i1/threads/t1/labels HTTP/1.1"
      end)
    end

    test "POST, PUT and PATCH without a body go out with an empty body and no content type" do
      serve(&json(&1, "{}"), fn port ->
        c = client(port)
        assert {:ok, _} = BillionSend.Domains.verify(c, "d1")
        assert {:ok, _} = BillionSend.Domains.update(c, "d1")
        assert {:ok, _} = BillionSend.Emails.cancel(c, "e1")

        for {method, path} <- [
              {"POST", "/domains/d1/verify"},
              {"PATCH", "/domains/d1"},
              {"POST", "/emails/e1/cancel"}
            ] do
          assert_received {:request, head, ""}
          assert head =~ "#{method} #{path} HTTP/1.1"
          assert head =~ ~r/content-length: 0(\r\n|\z)/i
          refute head =~ ~r/content-type/i
        end
      end)
    end

    test "a path with every awkward character reaches the server as written" do
      serve(&json(&1, "{}"), fn port ->
        assert {:ok, _} = BillionSend.Inboxes.get(client(port), "a+b@x.com \u00e9/?#%")
        assert_received {:request, head, _}
        assert head =~ "GET /inboxes/a%2Bb@x.com%20%C3%A9%2F%3F%23%25 HTTP/1.1"
      end)
    end

    test "a multipart upload keeps a non-ASCII file name and every byte, and its boundary matches" do
      serve(&json(&1, ~s({"object":"contact_import","id":"i1"})), fn port ->
        csv = "Email,Name\r\nada@example.com,\u00c4da\r\n"

        assert {:ok, %{"id" => "i1"}} =
                 BillionSend.Contacts.Imports.create(client(port), %{
                   file: {"\u8054\u7cfb\u4eba.csv", csv, "text/csv"},
                   on_conflict: "skip"
                 })

        assert_received {:request, head, body}

        assert [_, boundary] =
                 Regex.run(~r/content-type: multipart\/form-data; boundary=(\S+)\r\n/i, head)

        assert head =~ ~r/content-length: #{byte_size(body)}(\r\n|\z)/i
        assert String.starts_with?(body, "--#{boundary}\r\n")
        assert String.ends_with?(body, "\r\n--#{boundary}--\r\n")
        assert body =~ ~s(filename="\u8054\u7cfb\u4eba.csv")
        assert body =~ "Content-Type: text/csv\r\n\r\n#{csv}\r\n--#{boundary}"
      end)
    end

    test "a large body is sent whole" do
      serve(&json(&1, "{}"), fn port ->
        big = String.duplicate("x", 5_000_000)

        assert {:ok, _} =
                 BillionSend.Contacts.Imports.create(client(port, timeout: 30_000), %{
                   file: {"big.csv", big}
                 })

        assert_received {:request, _, body}
        assert byte_size(body) > 5_000_000
        assert body =~ big
      end)
    end

    test "a refused connection is a connection error, retried for a GET" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)
      parent = self()
      c = client(port, max_retries: 2, sleep: fn ms -> send(parent, {:slept, ms}) end)

      assert {:error, %BillionSend.APIConnectionError{message: "Connection error: " <> _}} =
               BillionSend.Domains.list(c)

      assert_received {:slept, _}
      assert_received {:slept, _}
      refute_received {:slept, _}
    end
  end

  # --- answers ---------------------------------------------------------------------------

  describe "every kind of answer" do
    test "204 without a body is {:ok, nil}" do
      serve(&send_all(&1, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"), fn port ->
        assert {:ok, nil} = BillionSend.Domains.list(client(port))
      end)
    end

    test "a body without a length, ended by the close, is read to the end" do
      serve(
        &send_all(
          &1,
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"a\":1}"
        ),
        fn port -> assert {:ok, %{"a" => 1}} = BillionSend.Domains.list(client(port)) end
      )
    end

    test "a large answer is read whole and decoded" do
      items = for i <- 1..20_000, do: %{"id" => "id-#{i}", "name" => String.duplicate("n", 40)}
      body = JSON.encode!(%{"object" => "list", "has_more" => false, "data" => items})

      serve(&json(&1, body), fn port ->
        assert {:ok, %{"data" => data}} = BillionSend.Domains.list(client(port))
        assert length(data) == 20_000
      end)
    end

    test "an HTML error page from a proxy is an APIError that keeps the page and the request id" do
      page = "<html><h1>502 Bad Gateway</h1></html>"

      serve(
        &send_all(
          &1,
          "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/html\r\nX-Request-Id: req_proxy\r\nContent-Length: #{byte_size(page)}\r\nConnection: close\r\n\r\n#{page}"
        ),
        fn port ->
          assert {:error, %BillionSend.APIError{} = error} =
                   BillionSend.Domains.list(client(port, max_retries: 0))

          assert error.message == page
          assert error.name == "application_error"
          assert error.request_id == "req_proxy"
          assert error.response.body == page
        end
      )
    end

    test "a redirect is not followed" do
      serve(
        &send_all(
          &1,
          "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        ),
        fn port ->
          assert {:error, %BillionSend.Error{status_code: 302}} =
                   BillionSend.Domains.list(client(port, max_retries: 0))

          assert_received {:request, _, _}
          refute_received {:request, _, _}
        end
      )
    end

    test "a 200 that is not JSON is an error that says what it got" do
      serve(
        &send_all(
          &1,
          "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 6\r\nConnection: close\r\n\r\n<html>"
        ),
        fn port ->
          assert {:error,
                  %BillionSend.Error{
                    status_code: 200,
                    message: "Expected a JSON answer, got text/html"
                  }} =
                   BillionSend.Domains.list(client(port))
        end
      )
    end

    test "an answer cut short is a connection error" do
      serve(
        &send_all(
          &1,
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{\"a\":"
        ),
        fn port ->
          assert {:error, %BillionSend.APIConnectionError{}} =
                   BillionSend.Domains.list(client(port, max_retries: 0))
        end
      )
    end

    test "a 429 with Retry-After is waited for, then the next answer is returned" do
      parent = self()

      serve(
        [
          &json(
            &1,
            ~s({"statusCode":429,"name":"rate_limit_exceeded","message":"Slow down"}),
            "429 Too Many Requests",
            "Retry-After: 2\r\n"
          ),
          &json(&1, ~s({"object":"list","has_more":false,"data":[]}))
        ],
        fn port ->
          c = client(port, sleep: fn ms -> send(parent, {:slept, ms}) end)
          assert {:ok, %{"data" => []}} = BillionSend.Domains.list(c)
          assert_received {:slept, 2000}
        end
      )
    end

    test "every attempt of a slow server times out, and a call's own timeout is the one that counts" do
      serve(fn _ -> Process.sleep(1_500) end, fn port ->
        c = client(port, max_retries: 1)
        started = System.monotonic_time(:millisecond)

        assert {:error, %BillionSend.APITimeoutError{}} = BillionSend.Domains.list(c, timeout: 200)
        assert System.monotonic_time(:millisecond) - started < 1_200
        assert_received {:request, _, _}
      end)
    end
  end

  # --- event streams ---------------------------------------------------------------------

  describe "event streams, in every framing" do
    test "with a Content-Length" do
      body = event(1) <> event(2)

      serve(
        &send_all(
          &1,
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
        ),
        fn port ->
          {:ok, stream} = BillionSend.Inboxes.Events.stream(client(port), max_reconnects: 0)
          assert Enum.map(Enum.take(stream, 2), & &1.id) == ~w(1 2)
        end
      )
    end

    test "ended only by the close" do
      serve(
        &send_all(
          &1,
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" <> event(1) <> event(2)
        ),
        fn port ->
          {:ok, stream} = BillionSend.Inboxes.Events.stream(client(port), max_reconnects: 0)
          assert Enum.map(Enum.take(stream, 2), & &1.id) == ~w(1 2)
        end
      )
    end

    test "chunked, with chunk extensions, one event split over reads and a chunk straddling a read" do
      wire = chunk(event(1)) <> chunk(event(2))

      serve(
        fn s ->
          send_all(
            s,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
          )

          {a, b} = String.split_at(String.replace(wire, ~r/\A([0-9a-f]+)\r\n/, "\\1;ext=1\r\n"), 3)
          send_all(s, a)
          Process.sleep(30)
          send_all(s, b)
          Process.sleep(30)
          send_all(s, "0\r\n\r\n")
        end,
        fn port ->
          {:ok, stream} = BillionSend.Inboxes.Events.stream(client(port), max_reconnects: 0)
          assert Enum.map(Enum.take(stream, 2), & &1.id) == ~w(1 2)
        end
      )
    end

    test "a body that arrives in pieces after the head, with a length and ended by the close" do
      for framing <- ["Content-Length: #{byte_size(event(1) <> event(2))}\r\n", ""] do
        serve(
          fn s ->
            send_all(s, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n#{framing}\r\n")
            Process.sleep(30)
            send_all(s, event(1))
            Process.sleep(30)
            send_all(s, event(2))
          end,
          fn port ->
            {:ok, stream} = BillionSend.Inboxes.Events.stream(client(port), max_reconnects: 0)
            assert Enum.map(Enum.take(stream, 2), & &1.id) == ~w(1 2)
          end
        )
      end
    end

    test "a body ended by the close ends the stream, and one that goes quiet in either framing is lost" do
      collect = fn stream ->
        parent = self()

        assert_raise BillionSend.APIConnectionError, fn ->
          Enum.each(stream, &send(parent, {:event, &1.id}))
        end
      end

      # Ended by the close: the events arrive, then the stream ends (and, with no reconnects, raises).
      serve(
        fn s ->
          send_all(s, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
          Process.sleep(30)
          send_all(s, event(1))
        end,
        fn port ->
          {:ok, stream} = BillionSend.Inboxes.Events.stream(client(port), max_reconnects: 0)
          collect.(stream)
          assert_received {:event, "1"}
        end
      )

      # Quiet, with a length still to come or with no length at all: the read times out.
      for framing <- ["Content-Length: 1000\r\n", ""] do
        serve(
          fn s ->
            send_all(
              s,
              "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n#{framing}\r\n" <> event(1)
            )

            Process.sleep(1_000)
          end,
          fn port ->
            c =
              client(port,
                timeout: 200,
                transport: {BillionSend.Transport.Httpc, stream_read_timeout: 200}
              )

            {:ok, stream} = BillionSend.Inboxes.Events.stream(c, max_reconnects: 0)
            collect.(stream)
            assert_received {:event, "1"}
          end
        )
      end
    end

    test "a connection closed in the middle of a chunk is a lost connection" do
      serve(
        &send_all(
          &1,
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n" <>
            chunk(event(1)) <> "ff\r\nid: 2"
        ),
        fn port ->
          {:ok, stream} = BillionSend.Inboxes.Events.stream(client(port), max_reconnects: 0)
          parent = self()

          assert_raise BillionSend.APIConnectionError, fn ->
            Enum.each(stream, &send(parent, {:event, &1.id}))
          end

          assert_received {:event, "1"}
          refute_received {:event, "2"}
        end
      )
    end

    test "a chunk size that is not a number drops the connection, and the stream says so" do
      serve(
        &send_all(
          &1,
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n"
        ),
        fn port ->
          {:ok, stream} = BillionSend.Inboxes.Events.stream(client(port), max_reconnects: 0)

          assert_raise BillionSend.APIConnectionError, ~r/gave up after 0 reconnects/, fn ->
            Enum.to_list(stream)
          end
        end
      )
    end

    test "an answer that is not HTTP is a connection error when opening" do
      serve(&send_all(&1, "SSH-2.0-nonsense\r\n\r\n"), fn port ->
        assert {:error, %BillionSend.APIConnectionError{message: "Malformed answer: " <> _}} =
                 BillionSend.Inboxes.Events.stream(client(port))
      end)
    end

    test "a refusal with a chunked error body is that error" do
      body = ~s({"statusCode":403,"name":"forbidden","message":"Needs a team-wide key"})

      serve(
        &send_all(
          &1,
          "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nX-Request-Id: req_s\r\n\r\n#{chunk(body)}0\r\n\r\n"
        ),
        fn port ->
          assert {:error,
                  %BillionSend.PermissionDeniedError{
                    message: "Needs a team-wide key",
                    request_id: "req_s"
                  }} =
                   BillionSend.Inboxes.Events.stream(client(port))
        end
      )
    end

    test "nothing to connect to is a connection error when opening" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      assert {:error, %BillionSend.APIConnectionError{}} =
               BillionSend.Inboxes.Events.stream(client(port))
    end

    test "a stream that goes quiet for its read timeout is lost, and reconnects count" do
      serve(
        fn s ->
          send_all(
            s,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n" <>
              chunk(event(1))
          )

          Process.sleep(1_000)
        end,
        fn port ->
          c =
            client(port,
              timeout: 200,
              transport: {BillionSend.Transport.Httpc, stream_read_timeout: 200}
            )

          {:ok, stream} = BillionSend.Inboxes.Events.stream(c, max_reconnects: 0)

          assert_raise BillionSend.APIConnectionError, fn -> Enum.to_list(stream) end
        end
      )
    end

    test "the resume position and the key travel in the request, and the stream's request is a plain GET" do
      serve(
        &send_all(&1, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" <> event(7)),
        fn port ->
          {:ok, stream} =
            BillionSend.Inboxes.Events.stream(client(port),
              last_event_id: "6",
              types: ["inbox.email.received", "inbox.deleted"]
            )

          assert [%{id: "7"}] = Enum.take(stream, 1)
          assert_received {:request, head, ""}
          assert head =~ "GET /inboxes/events?types=inbox.email.received%2Cinbox.deleted HTTP/1.1"
          assert head =~ ~r/last-event-id: 6(\r\n|\z)/i
          assert head =~ ~r/accept: text\/event-stream\r\n/i
          assert head =~ ~r/authorization: Bearer bs_wire_test(\r\n|\z)/i
          assert head =~ ~r/host: 127.0.0.1:\d+(\r\n|\z)/i
          assert head =~ ~r/connection: close(\r\n|\z)/i
        end
      )
    end
  end

  describe "the transports' own contracts" do
    test "a request that has a body and no content type goes out as JSON" do
      serve(&json(&1, "{}"), fn port ->
        req = %BillionSend.Request{
          method: "POST",
          url: "http://127.0.0.1:#{port}/x",
          headers: [],
          body: "{}"
        }

        assert {:ok, %BillionSend.Response{status: 200, body: "{}"}} =
                 BillionSend.Transport.Httpc.request(nil, req)

        assert_received {:request, head, "{}"}
        assert head =~ ~r/content-type: application\/json/i
      end)
    end

    test "reading a stream that is done, or closing something that is not a stream, is harmless" do
      assert BillionSend.Transport.Httpc.next_chunk(nil, :done) == :done
      assert BillionSend.Transport.Httpc.close_stream(nil, :done) == :ok

      assert BillionSend.Transport.SSEConnection.next(%BillionSend.Transport.SSEConnection{
               mode: :done
             }) == :done
    end
  end

  # --- TLS -------------------------------------------------------------------------------

  describe "HTTPS" do
    defp certificates(name \\ ~c"localhost") do
      {:ok, _} = Application.ensure_all_started(:ssl)
      key = {:key, {:rsa, 2048, 65537}}
      san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, name}]}

      %{server_config: server} =
        :public_key.pkix_test_data(%{
          server_chain: %{
            root: [key, {:digest, :sha256}],
            peer: [key, {:digest, :sha256}, {:extensions, [san]}]
          },
          client_chain: %{root: [], peer: []}
        })

      {server, Keyword.fetch!(server, :cacerts)}
    end

    defp tls_client(port, host, opts) do
      client(port, Keyword.merge([base_url: "https://#{host}:#{port}", max_retries: 0], opts))
    end

    test "a server the given CA vouches for is trusted, and gets the request" do
      {server, cacerts} = certificates()

      serve(&json(&1, ~s({"id":"d1"})), server, fn port ->
        c =
          tls_client(port, "localhost", transport: {BillionSend.Transport.Httpc, cacerts: cacerts})

        assert {:ok, %{"id" => "d1"}} = BillionSend.Domains.get(c, "d1")
        assert_received {:request, head, _}
        assert head =~ ~r/host: localhost:#{port}(\r\n|\z)/i
      end)
    end

    test "a server the system's CAs do not know is refused before anything is sent" do
      {server, _cacerts} = certificates()

      serve(&json(&1, "{}"), server, fn port ->
        assert {:error, %BillionSend.APIConnectionError{message: message}} =
                 BillionSend.Domains.list(tls_client(port, "localhost", []))

        assert message =~ "Connection error"
        refute_received {:request, _, _}
      end)
    end

    test "a certificate for another name is refused, even from a trusted CA" do
      {server, cacerts} = certificates(~c"somewhere-else.test")

      serve(&json(&1, "{}"), server, fn port ->
        c =
          tls_client(port, "localhost", transport: {BillionSend.Transport.Httpc, cacerts: cacerts})

        assert {:error, %BillionSend.APIConnectionError{}} = BillionSend.Domains.list(c)
        refute_received {:request, _, _}
      end)
    end

    test "CA certificates that cannot be read are a connection error that says so" do
      {server, _} = certificates()

      serve(&json(&1, "{}"), server, fn port ->
        c =
          tls_client(port, "localhost",
            transport: {BillionSend.Transport.Httpc, cacerts: :nonsense}
          )

        assert {:error, %BillionSend.APIConnectionError{message: "No CA certificates" <> _}} =
                 BillionSend.Domains.list(c)

        assert {:error, %BillionSend.APIConnectionError{message: "No CA certificates" <> _}} =
                 BillionSend.Inboxes.Events.stream(c)
      end)
    end

    test "an event stream over TLS, from a trusted server, and refused from an untrusted one" do
      {server, cacerts} = certificates()

      serve(
        &send_all(&1, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" <> event(1)),
        server,
        fn port ->
          trusted =
            tls_client(port, "localhost",
              transport: {BillionSend.Transport.Httpc, cacerts: cacerts}
            )

          assert {:ok, stream} = BillionSend.Inboxes.Events.stream(trusted, max_reconnects: 0)
          assert [%{id: "1"}] = Enum.take(stream, 1)
          assert_received {:request, _, _}
        end
      )

      serve(&json(&1, "{}"), server, fn port ->
        assert {:error, %BillionSend.APIConnectionError{}} =
                 BillionSend.Inboxes.Events.stream(tls_client(port, "localhost", []))

        refute_received {:request, _, _}
      end)
    end
  end
end
