defmodule BillionSend.Transport.SSEConnection do
  @moduledoc false
  # An event stream's HTTP/1.1 connection over :gen_tcp or :ssl, read as it
  # arrives. :httpc's streaming modes can hold a chunk back until the next
  # bytes come in, which for an event stream means an event waits for the next
  # keepalive (15 s); here every chunk is handed out as soon as it is read.

  alias BillionSend.{APIConnectionError, APITimeoutError, Request, Response}

  defstruct [:socket, :mod, :timeout, buffer: "", mode: :close]

  @doc false
  # Connects, sends the GET and reads the answer's head. A 2xx answer comes
  # back with a connection to read its body from; any other with its body read.
  def open(%Request{} = req, ssl_options, read_timeout) do
    uri = URI.parse(req.url)
    host = String.to_charlist(uri.host)
    port = uri.port || if(uri.scheme == "https", do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    tcp = [:binary, active: false, packet: :raw]

    connected =
      if uri.scheme == "https",
        do: :ssl.connect(host, port, tcp ++ ssl_options, req.timeout),
        else: :gen_tcp.connect(host, port, tcp, req.timeout)

    with {:ok, socket} <- wrap(connected),
         conn = %__MODULE__{
           socket: socket,
           mod: if(uri.scheme == "https", do: :ssl, else: :gen_tcp),
           timeout: req.timeout
         },
         :ok <- wrap(conn.mod.send(socket, request(req, uri, path))),
         {:ok, status, headers, conn} <- head(conn) do
      conn = %{conn | timeout: read_timeout, mode: body_mode(headers)}

      if status in 200..299 do
        {:ok, %Response{status: status, headers: headers}, conn}
      else
        body = read_all(conn, "")
        close(conn)
        {:ok, %Response{status: status, headers: headers, body: body}, :done}
      end
    else
      {:error, _} = error -> error
    end
  end

  @doc false
  # The next piece of the body: {:ok, bytes, conn}, :done, or {:error, error}.
  def next(%__MODULE__{mode: :done}), do: :done

  def next(%__MODULE__{mode: :chunked} = conn) do
    case :binary.match(conn.buffer, "\r\n") do
      :nomatch ->
        with {:ok, conn} <- more(conn), do: next(conn)

      {at, 2} ->
        size_line = binary_part(conn.buffer, 0, at)

        case Integer.parse(size_line |> String.split(";") |> hd() |> String.trim(), 16) do
          {0, _} ->
            :done

          {size, _} ->
            rest = binary_part(conn.buffer, at + 2, byte_size(conn.buffer) - at - 2)

            if byte_size(rest) >= size + 2 do
              <<data::binary-size(^size), _crlf::binary-2, tail::binary>> = rest
              {:ok, data, %{conn | buffer: tail}}
            else
              with {:ok, conn} <- more(conn), do: next(conn)
            end

          :error ->
            {:error, %APIConnectionError{message: "Malformed chunked body"}}
        end
    end
  end

  def next(%__MODULE__{mode: {:length, 0}}), do: :done

  def next(%__MODULE__{mode: {:length, left}, buffer: buffer} = conn) when buffer != "" do
    take = min(left, byte_size(buffer))
    <<data::binary-size(^take), tail::binary>> = buffer
    {:ok, data, %{conn | buffer: tail, mode: {:length, left - take}}}
  end

  def next(%__MODULE__{mode: :close, buffer: buffer} = conn) when buffer != "",
    do: {:ok, buffer, %{conn | buffer: ""}}

  def next(%__MODULE__{} = conn) do
    case conn.mod.recv(conn.socket, 0, conn.timeout) do
      {:ok, data} -> next(%{conn | buffer: conn.buffer <> data})
      {:error, :closed} when conn.mode == :close -> :done
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  def close(%__MODULE__{mod: mod, socket: socket}) do
    mod.close(socket)
    :ok
  end

  def close(_), do: :ok

  defp more(conn) do
    case conn.mod.recv(conn.socket, 0, conn.timeout) do
      {:ok, data} -> {:ok, %{conn | buffer: conn.buffer <> data}}
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  defp read_all(conn, acc) do
    case next(conn) do
      {:ok, data, conn} -> read_all(conn, acc <> data)
      _ -> acc
    end
  end

  defp request(req, uri, path) do
    host = if uri.port in [80, 443, nil], do: uri.host, else: "#{uri.host}:#{uri.port}"

    headers =
      req.headers
      |> Enum.reject(fn {k, _} -> String.downcase(k) in ["host", "connection"] end)
      |> Enum.map(fn {k, v} -> [k, ": ", v, "\r\n"] end)

    ["GET ", path, " HTTP/1.1\r\nHost: ", host, "\r\n", headers, "Connection: close\r\n\r\n"]
  end

  defp head(conn) do
    case :binary.match(conn.buffer, "\r\n\r\n") do
      {at, 4} ->
        head = binary_part(conn.buffer, 0, at)
        rest = binary_part(conn.buffer, at + 4, byte_size(conn.buffer) - at - 4)
        [status_line | lines] = String.split(head, "\r\n")

        with [_, code | _] <- String.split(status_line, " ", parts: 3),
             {status, ""} <- Integer.parse(code) do
          headers =
            for line <- lines,
                [k, v] <- [String.split(line, ":", parts: 2)],
                into: %{},
                do: {String.downcase(String.trim(k)), String.trim(v)}

          {:ok, status, headers, %{conn | buffer: rest}}
        else
          _ -> {:error, %APIConnectionError{message: "Malformed answer: #{inspect(status_line)}"}}
        end

      :nomatch ->
        with {:ok, conn} <- more(conn), do: head(conn)
    end
  end

  defp body_mode(headers) do
    cond do
      String.downcase(headers["transfer-encoding"] || "") =~ "chunked" -> :chunked
      headers["content-length"] -> {:length, String.to_integer(headers["content-length"])}
      true -> :close
    end
  end

  defp wrap({:ok, _} = ok), do: ok
  defp wrap(:ok), do: :ok
  defp wrap({:error, reason}), do: {:error, failure(reason)}

  defp failure(:timeout), do: %APITimeoutError{message: "Request timed out"}
  defp failure(:closed), do: %APIConnectionError{message: "Connection closed"}
  defp failure(reason), do: %APIConnectionError{message: "Connection error: #{inspect(reason)}"}
end
