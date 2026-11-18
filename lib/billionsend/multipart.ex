defmodule BillionSend.Multipart do
  @moduledoc """
  Encodes the fields of a `multipart/form-data` request (a CSV upload).

  A field is `name => value`, names as atoms or strings:

    * a string, number or boolean is sent as text;
    * `{filename, content}` or `{filename, content, content_type}` is a file
      part (`content_type` defaults to `application/octet-stream`);
    * anything else (a map or a list) is sent as its JSON text, which is how
      the API takes the structured fields of a form;
    * `nil` leaves the field out.
  """

  @type file :: {String.t(), iodata()} | {String.t(), iodata(), String.t()}

  @doc "Returns `{content_type, body}`: the `Content-Type` header value, boundary included, and the encoded body."
  @spec encode(map() | keyword()) :: {String.t(), binary()}
  def encode(fields) when is_map(fields) or is_list(fields) do
    boundary = "billionsend-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    parts =
      for {name, value} <- fields, value != nil do
        ["--", boundary, "\r\n", part(to_string(name), value), "\r\n"]
      end

    body = IO.iodata_to_binary([parts, "--", boundary, "--\r\n"])
    {"multipart/form-data; boundary=" <> boundary, body}
  end

  defp part(name, {filename, content}),
    do: part(name, {filename, content, "application/octet-stream"})

  defp part(name, {filename, content, content_type}) do
    [
      ~s(Content-Disposition: form-data; name="#{escape(name)}"; filename="#{escape(filename)}"\r\n),
      "Content-Type: ",
      header_value(content_type),
      "\r\n\r\n",
      content
    ]
  end

  defp part(name, value) do
    [~s(Content-Disposition: form-data; name="#{escape(name)}"\r\n\r\n), text(value)]
  end

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp text(value), do: JSON.encode!(value)

  # A quote, a backslash or a line break in a name would end the header value early.
  defp escape(value) do
    value
    |> to_string()
    |> String.replace(["\r", "\n"], "")
    |> String.replace(["\\", "\""], &("\\" <> &1))
  end

  defp header_value(value), do: value |> to_string() |> String.replace(["\r", "\n"], "")
end
