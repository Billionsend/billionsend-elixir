defmodule BillionSend.Test.ContractServer do
  @moduledoc """
  A real HTTP server on a local port that answers like the contract mock: every
  request that reaches it is turned into a `BillionSend.Request` and handled by
  `BillionSend.Test.Mock`, so the contract checks and the queued answers are the
  same, but the SDK reaches it through its default transport, with a client built
  the way a user builds one (`BILLIONSEND_BASE_URL` and `BILLIONSEND_API_KEY`).

  An answer queued with `error: :hold` leaves its event stream open once its
  chunks are sent. Close the server with `stop/1`.
  """
  alias BillionSend.Request
  alias BillionSend.Test.{Contract, Mock}

  @reasons %{
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    204 => "No Content",
    400 => "Bad Request",
    401 => "Unauthorized",
    403 => "Forbidden",
    404 => "Not Found",
    409 => "Conflict",
    422 => "Unprocessable Entity",
    429 => "Too Many Requests",
    500 => "Internal Server Error",
    503 => "Service Unavailable"
  }

  def start(mock) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept(listen, mock) end)
    %{port: port, listen: listen, pid: pid, base_url: "http://127.0.0.1:#{port}"}
  end

  def stop(%{listen: listen, pid: pid}) do
    :gen_tcp.close(listen)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :ok
  end

  defp accept(listen, mock) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        handler = spawn(fn -> handle(socket, mock) end)
        :gen_tcp.controlling_process(socket, handler)
        accept(listen, mock)

      {:error, _} ->
        :ok
    end
  end

  defp handle(socket, mock) do
    {head, body} = read(socket, "")
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, target | _] = String.split(request_line, " ")

    headers =
      for line <- header_lines,
          [k, v] <- [String.split(line, ":", parts: 2)],
          do: {k, String.trim(v)}

    request = %Request{
      method: method,
      url: Contract.base_url() <> target,
      headers: headers,
      body: if(body == "", do: nil, else: body)
    }

    case Mock.serve(mock, request) do
      {:fail, _} -> :gen_tcp.close(socket)
      answer -> respond(socket, answer)
    end
  catch
    _, _ -> :gen_tcp.close(socket)
  end

  defp respond(socket, %{chunks: chunks} = answer) when is_list(chunks) do
    :gen_tcp.send(socket, head(answer, "Transfer-Encoding: chunked\r\n"))

    for chunk <- chunks do
      :gen_tcp.send(socket, Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n")
    end

    if answer.error == :hold do
      # Open until the client lets go.
      :inet.setopts(socket, active: true)

      receive do
        {:tcp_closed, _} -> :ok
        {:tcp_error, _, _} -> :ok
      end
    else
      :gen_tcp.send(socket, "0\r\n\r\n")
      :gen_tcp.close(socket)
    end
  end

  defp respond(socket, answer) do
    :gen_tcp.send(
      socket,
      head(answer, "Content-Length: #{byte_size(answer.body)}\r\n") <> answer.body
    )

    :gen_tcp.close(socket)
  end

  defp head(answer, framing) do
    extra = Enum.map_join(answer.headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

    "HTTP/1.1 #{answer.status} #{Map.get(@reasons, answer.status, "Status")}\r\n#{extra}#{framing}Connection: close\r\n\r\n"
  end

  defp read(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        length =
          case Regex.run(~r/content-length: (\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            nil -> 0
          end

        {head, read_body(socket, body, length)}

      _ ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read(socket, acc <> data)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: body

  defp read_body(socket, body, length) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, body <> data, length)
  end
end
