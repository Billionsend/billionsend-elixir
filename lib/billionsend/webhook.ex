defmodule BillionSend.Webhook do
  @moduledoc """
  Verifies the signature of a webhook delivery.

  BillionSend signs every delivery the Standard Webhooks way: the secret is
  `whsec_` followed by base64 of 24 to 64 bytes, the signed content is
  `<webhook-id>.<webhook-timestamp>.<body>`, and `webhook-signature` holds
  `v1,<base64 HMAC-SHA256>`, several space-separated during a secret rotation.
  """

  alias BillionSend.WebhookVerificationError

  @default_tolerance 300

  @doc """
  Checks a webhook delivery; returns `{:ok, event}` (the parsed body, a map
  with "type", "created_at" and "data") or `{:error, %BillionSend.WebhookVerificationError{}}`.

    * `payload` - the request body exactly as received, before any JSON
      parsing: re-serialised JSON does not verify
    * `headers` - the request headers as a map or a list of pairs; names are
      matched case-insensitively (webhook-id, webhook-timestamp, webhook-signature)
    * `secret` - the endpoint's signing secret (`whsec_...`); anything else
      raises `ArgumentError`

  Options: `:tolerance` - seconds the timestamp may be off the current time,
  either way (default #{@default_tolerance}; this bounds replays of a captured
  delivery); `:now` - the current Unix time, for tests.
  """
  @spec verify(binary(), map() | [{String.t(), String.t()}], String.t(), keyword()) ::
          {:ok, map()} | {:error, WebhookVerificationError.t()}
  def verify(payload, headers, secret, opts \\ []) do
    key = secret_key!(secret)
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, id, timestamp, signatures} <- read_headers(headers),
         :ok <- check_timestamp(timestamp, now, tolerance),
         :ok <- check_signature(key, id, timestamp, payload, signatures) do
      case JSON.decode(payload) do
        {:ok, %{} = event} -> {:ok, event}
        {:ok, _} -> fail("Webhook body is not a JSON object")
        {:error, _} -> fail("Webhook body is not JSON")
      end
    end
  end

  @doc "Like `verify/4`, but returns the event or raises."
  @spec verify!(binary(), map() | [{String.t(), String.t()}], String.t(), keyword()) :: map()
  def verify!(payload, headers, secret, opts \\ []) do
    BillionSend.Client.unwrap!(verify(payload, headers, secret, opts))
  end

  defp fail(message),
    do: {:error, %WebhookVerificationError{message: message, name: "webhook_verification_error"}}

  defp read_headers(headers) do
    values =
      for name <- ~w(webhook-id webhook-timestamp webhook-signature), do: header(headers, name)

    case values do
      [id, timestamp, signatures]
      when is_binary(id) and is_binary(timestamp) and is_binary(signatures) ->
        {:ok, id, timestamp, signatures}

      _ ->
        fail("Missing webhook-id, webhook-timestamp or webhook-signature")
    end
  end

  defp check_timestamp(timestamp, now, tolerance) do
    if timestamp =~ ~r/\A[0-9]+\z/ do
      if abs(now - String.to_integer(timestamp)) > tolerance,
        do: fail("Webhook timestamp is outside the tolerance"),
        else: :ok
    else
      fail("Invalid webhook-timestamp")
    end
  end

  defp check_signature(key, id, timestamp, payload, signatures) do
    expected = :crypto.mac(:hmac, :sha256, key, [id, ".", timestamp, ".", payload])

    matched =
      signatures
      |> String.split(" ")
      |> Enum.any?(fn candidate ->
        with ["v1", encoded] when encoded != "" <- String.split(candidate, ",", parts: 2),
             {:ok, given} <- Base.decode64(encoded),
             true <- byte_size(given) == byte_size(expected) do
          :crypto.hash_equals(given, expected)
        else
          _ -> false
        end
      end)

    if matched, do: :ok, else: fail("No webhook signature matches")
  end

  defp secret_key!("whsec_" <> encoded) do
    key =
      case Base.decode64(encoded) do
        {:ok, key} -> key
        :error -> raise ArgumentError, "A webhook secret is whsec_ followed by base64"
      end

    unless byte_size(key) in 24..64,
      do: raise(ArgumentError, "A webhook secret holds 24 to 64 bytes")

    unless Base.encode64(key) == encoded,
      do: raise(ArgumentError, "A webhook secret is whsec_ followed by base64")

    key
  end

  defp secret_key!(_), do: raise(ArgumentError, "A webhook secret starts with whsec_")

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      value = if is_list(value), do: List.first(value), else: value

      if String.downcase(to_string(key)) == name and value not in [nil, ""],
        do: to_string(value)
    end)
  end
end
