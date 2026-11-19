defmodule BillionSend.ConnectionTest do
  @moduledoc """
  The default transport's connection discipline, on real sockets: every request
  gets a connection of its own, so an answer is never held up behind another
  request, a connection the server keeps open, or one that has gone silent.
  """
  use ExUnit.Case, async: false

  @body ~s({"id":"x"})

  # The answer of a server that ignores `Connection: close`: keep-alive, and the
  # socket left open.
  @keep_alive "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
                "Content-Length: #{byte_size(@body)}\r\nConnection: keep-alive\r\n\r\n#{@body}"

  # A server that hands every accepted connection to `handler.(socket, n)`, n counting
  # from 0. Each connection is announced to the test as {:accepted, n}.
  defp serve(handler) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true, backlog: 256])

    {:ok, port} = :inet.port(listen)
    parent = self()
    acceptor = spawn_link(fn -> accept(listen, handler, parent, 0) end)

    on_exit(fn ->
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept(listen, handler, parent, n) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        send(parent, {:accepted, n})
        spawn(fn -> handler.(socket, n) end)
        accept(listen, handler, parent, n + 1)

      {:error, _} ->
        :ok
    end
  end

  defp read_request(socket, acc \\ "") do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        length =
          case Regex.run(~r/content-length: (\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            nil -> 0
          end

        if byte_size(body) < length do
          {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
          read_request(socket, acc <> data)
        else
          head
        end

      _ ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, acc <> data)
    end
  end

  defp client(url, opts),
    do:
      BillionSend.client(
        Keyword.merge([api_key: "bs_socket_test", base_url: url, max_retries: 0], opts)
      )

  defp elapsed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  test "each request opens its own connection, asks for it to close and is answered at once, whatever the server does with the socket" do
    parent = self()

    url =
      serve(fn socket, _n ->
        head = read_request(socket)
        send(parent, {:head, head})
        :gen_tcp.send(socket, @keep_alive)
        Process.sleep(:infinity)
      end)

    c = client(url, timeout: 2_000)

    for method <- ~w(GET POST GET POST PUT DELETE) do
      {result, ms} =
        elapsed(fn ->
          BillionSend.Client.request(c, method, "/x",
            body: if(method == "GET", do: nil, else: %{a: 1})
          )
        end)

      assert {:ok, %{"id" => "x"}} = result
      assert ms < 1_000, "#{method} waited #{ms} ms for an answer that was already sent"
    end

    heads =
      for _ <- 1..6,
          do:
            (
              assert_receive {:head, head}
              head
            )

    assert Enum.all?(heads, &(&1 =~ ~r/^connection: close\z/im))
    for n <- 0..5, do: assert_received({:accepted, ^n})
    refute_received {:accepted, 6}
  end

  test "a request that timed out leaves the next one unaffected" do
    url =
      serve(fn socket, n ->
        read_request(socket)

        if n == 0 do
          # Silent: never answers.
          Process.sleep(:infinity)
        else
          :gen_tcp.send(socket, @keep_alive)
          Process.sleep(:infinity)
        end
      end)

    c = client(url, timeout: 400)

    {first, _} = elapsed(fn -> BillionSend.Client.request(c, "POST", "/x", body: %{a: 1}) end)
    assert {:error, %BillionSend.APITimeoutError{}} = first

    {second, ms} = elapsed(fn -> BillionSend.Client.request(c, "POST", "/x", body: %{a: 1}) end)
    assert {:ok, %{"id" => "x"}} = second
    assert ms < 300, "the next request waited #{ms} ms behind the one that timed out"
  end

  test "requests in flight together are each answered without waiting for the others" do
    url =
      serve(fn socket, _n ->
        read_request(socket)
        Process.sleep(200)
        :gen_tcp.send(socket, @keep_alive)
        Process.sleep(:infinity)
      end)

    c = client(url, timeout: 5_000)

    {results, ms} =
      elapsed(fn ->
        1..40
        |> Task.async_stream(
          fn i ->
            if rem(i, 2) == 0,
              do: BillionSend.Client.request(c, "POST", "/x", body: %{a: i}),
              else: BillionSend.Client.request(c, "GET", "/x")
          end,
          max_concurrency: 40,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)
      end)

    assert Enum.all?(results, &match?({:ok, %{"id" => "x"}}, &1))
    # One 200 ms wait, not forty in a row.
    assert ms < 2_000
  end
end
