defmodule BillionSend.LiveHarnessTest do
  @moduledoc """
  The live tests' harness refuses unsafe requests before anything is sent: only
  simulator recipients, never an address that was put on the suppression list.
  Offline: nothing here reaches the network.
  """
  use ExUnit.Case, async: true

  alias BillionSend.Request
  alias BillionSend.Test.Live

  defp post(path, body) do
    %Request{
      method: "POST",
      url: Live.base_url() <> path,
      headers: [{"Content-Type", "application/json"}, {"Authorization", "Bearer bs_x"}],
      body: JSON.encode!(body)
    }
  end

  defp guard(body, path \\ "/emails", suppressed \\ MapSet.new()),
    do: Live.guard(suppressed, post(path, body))

  test "the simulator's success address and its plus-aliases are the only recipients" do
    for to <- [
          "success@simulator.amazonses.com",
          "success+sdk-e2e-elixir-ab12-one@simulator.amazonses.com",
          "SDK <success+x@simulator.amazonses.com>",
          ["success@simulator.amazonses.com", "success+b@simulator.amazonses.com"]
        ] do
      assert {:ok, _} = guard(%{to: to, subject: "s"})
    end
  end

  test "any other recipient is refused, in to, cc or bcc" do
    for bad <- [
          "ada@example.com",
          "bounce@simulator.amazonses.com",
          "complaint@simulator.amazonses.com",
          "suppressionlist@simulator.amazonses.com",
          "ooto@simulator.amazonses.com",
          "success@simulator.amazonses.com.example.net",
          "xsuccess@simulator.amazonses.com",
          "success+@simulator.amazonses.com",
          "success@simulator.amazonses.com, ada@example.com",
          ""
        ] do
      for field <- [:to, :cc, :bcc] do
        body = Map.put(%{to: "success@simulator.amazonses.com"}, field, [bad])
        assert {:error, reason} = guard(body), "should refuse #{inspect(bad)} in #{field}"
        assert reason =~ "not success@simulator.amazonses.com"
      end
    end
  end

  test "one bad message in a batch refuses the batch" do
    ok = %{to: ["success@simulator.amazonses.com"]}
    assert {:ok, _} = guard([ok, ok], "/emails/batch")
    assert {:error, _} = guard([ok, %{to: ["ada@example.com"]}], "/emails/batch")
  end

  test "forwards and replies are held to the same rule" do
    assert {:error, _} = guard(%{to: ["ada@example.com"]}, "/emails/receiving/x/forward")
    assert {:error, _} = guard(%{cc: ["ada@example.com"]}, "/inboxes/i/threads/t/emails/e/reply")
  end

  test "an address put on the suppression list is never a recipient, however it was put there" do
    {:ok, suppressed} =
      guard(%{email: "success+sdk-e2e-elixir-ab12-sup@simulator.amazonses.com"}, "/suppressions")

    {:ok, suppressed} =
      guard(
        %{emails: ["Success+Batch@simulator.amazonses.com"]},
        "/suppressions/batch/add",
        suppressed
      )

    assert MapSet.size(suppressed) == 2

    for to <- [
          "success+sdk-e2e-elixir-ab12-sup@simulator.amazonses.com",
          "success+batch@simulator.amazonses.com",
          "N <SUCCESS+batch@simulator.amazonses.com>"
        ] do
      assert {:error, reason} = guard(%{to: [to]}, "/emails", suppressed)
      assert reason =~ "suppression list"
    end

    # Other simulator addresses are still fine.
    assert {:ok, _} =
             guard(%{to: ["success+another@simulator.amazonses.com"]}, "/emails", suppressed)
  end

  test "the request that suppresses an address is not itself a send, and bodies without recipients pass" do
    assert {:ok, _} = guard(%{email: "ada@example.com"}, "/contacts")
    assert {:ok, _} = guard(%{name: "x"}, "/segments")

    assert {:ok, _} =
             Live.guard(MapSet.new(), %Request{
               method: "GET",
               url: Live.base_url() <> "/emails",
               headers: []
             })

    multipart = %Request{
      method: "POST",
      url: Live.base_url() <> "/contacts/imports",
      headers: [{"content-type", "multipart/form-data; boundary=x"}],
      body: "to: ada@example.com"
    }

    assert {:ok, _} = Live.guard(MapSet.new(), multipart)
  end

  test "through the transport a refused request raises and is never counted or sent" do
    agent = Live.start("bs_never_used")

    assert_raise RuntimeError, ~r/refused before sending: a recipient that is not/, fn ->
      Live.request(
        agent,
        post("/emails", %{to: ["ada@example.com"], from: "x", subject: "s", text: "t"})
      )
    end

    assert Live.requests(agent) == 0
    assert Live.log(agent) == []
  end

  test "a body that cannot be read, or a recipient that is not text, is refused rather than skipped" do
    for to <- [
          5,
          %{"email" => "success@simulator.amazonses.com"},
          [nil],
          [["success@simulator.amazonses.com"]],
          true
        ] do
      for field <- [:to, :cc, :bcc] do
        assert {:error, reason} =
                 guard(Map.put(%{to: "success@simulator.amazonses.com"}, field, to)),
               "should refuse #{inspect(to)}"

        assert reason =~ "not text"
      end
    end

    assert {:error, reason} = guard([%{to: "success@simulator.amazonses.com"}, 7], "/emails/batch")
    assert reason =~ "not an object"
    assert {:error, _} = guard("a bare string")

    broken = %{post("/emails", %{}) | body: ~s({"to": ["success@simulator.amazonses.com")}
    assert {:error, reason} = Live.guard(MapSet.new(), broken)
    assert reason =~ "not valid JSON"

    for type <- ["text/plain", "application/octet-stream", "", "multipart/form-data; boundary=x"] do
      odd = %{post("/emails", %{}) | headers: [{"content-type", type}], body: "to=ada@example.com"}
      assert {:error, reason} = Live.guard(MapSet.new(), odd)
      assert reason =~ "cannot be checked"
    end

    # null is no recipient.
    assert {:ok, _} = guard(%{to: "success@simulator.amazonses.com", cc: nil})
  end
end
