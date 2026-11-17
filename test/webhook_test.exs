defmodule BillionSend.WebhookTest do
  @moduledoc """
  Webhook signature verification, against the API's signing vectors: the
  published Standard Webhooks vector the API's own signing test pins, and a
  rotation vector signed the way the API signs.
  """
  use ExUnit.Case, async: true

  @secret "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
  @msg_id "msg_p5jXN8AQM9LWM0D4loKWxJek"
  @timestamp 1_614_265_330
  @payload ~s({"test": 2432232314})
  @signature "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
  @headers %{
    "webhook-id" => @msg_id,
    "webhook-timestamp" => "1614265330",
    "webhook-signature" => @signature
  }

  @rotated "whsec_BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="
  @rotation_payload ~s({"type":"email.delivered","created_at":"2026-11-16T09:00:00.000Z","data":{"email_id":"e1"}})
  @rotation_signature "v1,VfgCmhkRJMAi9nv9R1rsE49fWcTpLQ8gcMN9e7uGbrk= v1,IRvb7GZmh00vSNTRcSQ0MTb0qfbEKpRQlNS8r3daFnQ="

  defp verify(payload \\ @payload, headers \\ @headers, secret \\ @secret, opts \\ []) do
    BillionSend.verify_webhook(payload, headers, secret, Keyword.put_new(opts, :now, @timestamp))
  end

  test "published vector" do
    assert verify() == {:ok, %{"test" => 2_432_232_314}}
  end

  test "any header case, a list of pairs" do
    headers = for {k, v} <- @headers, do: {String.upcase(k), v}
    assert {:ok, _} = verify(@payload, headers)
  end

  test "either secret verifies during a rotation" do
    headers = %{
      "webhook-id" => "msg_rot",
      "webhook-timestamp" => "1700000000",
      "webhook-signature" => @rotation_signature
    }

    for secret <- [@rotated, @secret] do
      assert {:ok, event} = verify(@rotation_payload, headers, secret, now: 1_700_000_000)
      assert event["type"] == "email.delivered"
      assert event["data"] == %{"email_id" => "e1"}
    end
  end

  test "a changed body fails" do
    assert {:error, %BillionSend.WebhookVerificationError{}} = verify(~s({"test": 2432232315}))
  end

  test "a wrong secret fails" do
    secret = "whsec_" <> Base.encode64(String.duplicate("k", 24))
    assert {:error, %{message: "No webhook signature matches"}} = verify(@payload, @headers, secret)
  end

  test "the timestamp must be within the tolerance" do
    assert {:error, _} = verify(@payload, @headers, @secret, now: @timestamp + 301)
    assert {:error, _} = verify(@payload, @headers, @secret, now: @timestamp - 301)
    assert {:ok, _} = verify(@payload, @headers, @secret, now: @timestamp + 301, tolerance: 400)
  end

  test "missing or malformed headers fail" do
    for name <- Map.keys(@headers),
        do: assert({:error, _} = verify(@payload, Map.delete(@headers, name)))

    assert {:error, _} = verify(@payload, %{@headers | "webhook-timestamp" => "16142653e3"})
    [_, sig] = String.split(@signature, ",")
    assert {:error, _} = verify(@payload, %{@headers | "webhook-signature" => "v2," <> sig})
  end

  test "a body that is not an object fails" do
    key = String.duplicate("k", 32)
    signed = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{@msg_id}.#{@timestamp}.[1]"))
    headers = %{@headers | "webhook-signature" => "v1," <> signed}

    assert {:error, %{message: "Webhook body is not a JSON object"}} =
             verify("[1]", headers, "whsec_" <> Base.encode64(key))
  end

  test "bad secrets are refused" do
    for secret <- [
          "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw",
          "whsec_!!!",
          "whsec_" <> Base.encode64(String.duplicate("k", 8)),
          "whsec_" <> Base.encode64(String.duplicate("k", 65))
        ] do
      assert_raise ArgumentError, fn -> verify(@payload, @headers, secret) end
    end
  end

  test "verify_webhook! returns the event or raises" do
    assert BillionSend.verify_webhook!(@payload, @headers, @secret, now: @timestamp) == %{
             "test" => 2_432_232_314
           }

    assert_raise BillionSend.WebhookVerificationError, fn ->
      BillionSend.verify_webhook!(@payload, @headers, @secret)
    end
  end
end
