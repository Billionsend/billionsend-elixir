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

  describe "against a delivery signed here, the way the API signs" do
    @key String.duplicate("k", 32)
    @whsec "whsec_" <> Base.encode64(@key)

    defp signed(payload, opts \\ []) do
      id = Keyword.get(opts, :id, "msg_1")
      timestamp = Keyword.get(opts, :timestamp, System.os_time(:second))
      key = Keyword.get(opts, :key, @key)
      mac = :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{payload}")
      signature = "v1," <> Base.encode64(mac)

      %{
        "webhook-id" => id,
        "webhook-timestamp" => to_string(timestamp),
        "webhook-signature" => Keyword.get(opts, :signature, signature)
      }
    end

    test "verifies with the real clock when no :now is given, with or without options" do
      body = ~s({"type":"email.sent","created_at":"2026-11-19T00:00:00.000Z","data":{}})

      assert {:ok, %{"type" => "email.sent"}} =
               BillionSend.verify_webhook(body, signed(body), @whsec)

      assert %{"type" => "email.sent"} = BillionSend.verify_webhook!(body, signed(body), @whsec)

      assert %{"type" => "email.sent"} =
               BillionSend.verify_webhook!(body, signed(body), @whsec, tolerance: 10)
    end

    test "the tolerance is exact, in both directions" do
      body = ~s({"a":1})
      now = 1_800_000_000
      headers = signed(body, timestamp: now)
      assert {:ok, _} = BillionSend.verify_webhook(body, headers, @whsec, now: now, tolerance: 0)

      assert {:error, _} =
               BillionSend.verify_webhook(body, headers, @whsec, now: now + 1, tolerance: 0)

      assert {:error, _} =
               BillionSend.verify_webhook(body, headers, @whsec, now: now - 1, tolerance: 0)

      assert {:ok, _} = BillionSend.verify_webhook(body, headers, @whsec, now: now + 300)

      assert {:error, %{message: "Webhook timestamp is outside the tolerance"}} =
               BillionSend.verify_webhook(body, headers, @whsec, now: now - 301)
    end

    test "an empty body verifies as a signature and then fails as JSON" do
      assert {:error, %{message: "Webhook body is not JSON"}} =
               BillionSend.verify_webhook("", signed(""), @whsec)
    end

    test "the signature header: extra spaces are fine, v1 must be lower case, only v1 counts" do
      body = ~s({"a":1})
      headers = signed(body)
      [_, sig] = String.split(headers["webhook-signature"], ",")

      for ok <- ["  v1,#{sig}", "v1,#{sig}  ", "v2,AAAA   v1,#{sig}", "v1,#{sig} v1,#{sig}"] do
        assert {:ok, _} =
                 BillionSend.verify_webhook(body, %{headers | "webhook-signature" => ok}, @whsec)
      end

      for bad <- [
            "V1,#{sig}",
            "v2,#{sig}",
            "v1,",
            "v1",
            "",
            "#{sig}",
            "v1,#{String.downcase(sig)}",
            "v1,!!!!",
            "v1,#{sig}x"
          ] do
        assert {:error, %BillionSend.WebhookVerificationError{}} =
                 BillionSend.verify_webhook(body, %{headers | "webhook-signature" => bad}, @whsec),
               "should refuse #{inspect(bad)}"
      end
    end

    test "a signature for another id, another timestamp or another secret fails" do
      body = ~s({"a":1})
      headers = signed(body)

      assert {:error, _} =
               BillionSend.verify_webhook(body, %{headers | "webhook-id" => "msg_2"}, @whsec)

      assert {:error, _} =
               BillionSend.verify_webhook(
                 body,
                 %{headers | "webhook-timestamp" => to_string(System.os_time(:second) + 1)},
                 @whsec
               )

      other = "whsec_" <> Base.encode64(String.duplicate("z", 32))
      assert {:error, _} = BillionSend.verify_webhook(body, headers, other)
    end

    test "a header given as a list of values uses the first, an empty one counts as missing" do
      body = ~s({"a":1})
      headers = signed(body)

      assert {:ok, _} =
               BillionSend.verify_webhook(body, Map.new(headers, fn {k, v} -> {k, [v]} end), @whsec)

      assert {:error, %{message: "Missing" <> _}} =
               BillionSend.verify_webhook(body, %{headers | "webhook-id" => ""}, @whsec)

      assert {:ok, _} = BillionSend.verify_webhook(body, Map.to_list(headers), @whsec)

      assert {:ok, _} =
               BillionSend.verify_webhook(
                 body,
                 Enum.map(headers, fn {k, v} -> {String.to_atom(k), v} end),
                 @whsec
               )
    end

    test "secrets of 24 and 64 bytes are accepted, other lengths and spellings raise" do
      body = ~s({"a":1})

      for size <- [24, 64] do
        key = :crypto.strong_rand_bytes(size)

        assert {:ok, _} =
                 BillionSend.verify_webhook(
                   body,
                   signed(body, key: key),
                   "whsec_" <> Base.encode64(key)
                 )
      end

      for bad <- [
            "whsec_",
            "x" <> @whsec,
            String.replace(@whsec, "=", ""),
            String.replace(@whsec, ~r/.=\z/, "t="),
            nil,
            5
          ] do
        assert_raise ArgumentError, fn -> BillionSend.verify_webhook(body, signed(body), bad) end
      end
    end

    test "whitespace around the secret, a header value or between signatures does not matter" do
      body = ~s({"a":1})
      headers = signed(body)
      [_, sig] = String.split(headers["webhook-signature"], ",")

      for secret <- [@whsec <> "\n", "  " <> @whsec <> "\r\n", "\t" <> @whsec] do
        assert {:ok, _} = BillionSend.verify_webhook(body, headers, secret)
      end

      padded = Map.new(headers, fn {k, v} -> {k, "  " <> v <> "\r\n"} end)
      assert {:ok, _} = BillionSend.verify_webhook(body, padded, @whsec)

      for list <- [
            "v1,AAAA\tv1,#{sig}",
            "v1,AAAA\n v1,#{sig}",
            "\nv1,#{sig}\n",
            "v1,AAAA   \t  v1,#{sig}"
          ] do
        assert {:ok, _} =
                 BillionSend.verify_webhook(body, %{headers | "webhook-signature" => list}, @whsec)
      end
    end

    test "a payload that was parsed already and headers that are not headers raise, naming the mistake" do
      error =
        assert_raise ArgumentError, fn -> BillionSend.verify_webhook(%{"a" => 1}, %{}, @whsec) end

      assert error.message =~ "exactly as received"

      assert_raise ArgumentError, ~r/exactly as received/, fn ->
        BillionSend.verify_webhook(nil, %{}, @whsec)
      end

      assert_raise ArgumentError, ~r/headers/, fn ->
        BillionSend.verify_webhook("{}", nil, @whsec)
      end
    end

    test "unknown fields and nulls in the event come back as they were sent" do
      body =
        ~s({"type":"email.bounced","created_at":null,"data":{"new_field":[1,null],"bounce":{"type":"Permanent"}},"extra":true})

      assert {:ok, event} = BillionSend.verify_webhook(body, signed(body), @whsec)
      assert event == JSON.decode!(body)
    end
  end
end
