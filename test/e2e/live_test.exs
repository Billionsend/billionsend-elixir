defmodule BillionSend.LiveTest do
  @moduledoc """
  The SDK against the real BillionSend API. Not part of `mix test` and not run by
  CI: `BILLIONSEND_E2E_API_KEY=bs_... mix e2e` (see "Live tests" in the README).

  Every request the SDK builds is checked against the freshly published OpenAPI
  document before it is sent, and every answer after it is received
  (`BillionSend.Test.Live`), so a snapshot that has fallen behind the API fails
  here. The rules this suite keeps (it runs against a real company account):

    * the existing objects are only read; what is created carries the name
      `sdk-e2e-elixir-<random>` and is deleted again, also when a test fails;
    * mail goes only from `SDK E2E <sdk-e2e@mail.billionsend.dev>` and only to
      `success@simulator.amazonses.com` (plus-aliases of it), at most 20 emails;
      contacts are only `success+sdk-e2e-elixir-...@simulator.amazonses.com`
      addresses, and nobody is ever unsubscribed;
    * no domain is created or claimed, no broadcast is sent, no webhook secret,
      API key or OAuth grant of the account is touched, no automation is enabled,
      no inbox is used, no event stream is opened;
    * at most 150 requests, one a second.

  What cannot be tested live under these rules is listed at the end of the file.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias BillionSend.Test.{Contract, Live}

  @moduletag :e2e
  @moduletag timeout: 900_000

  @sender "SDK E2E <sdk-e2e@mail.billionsend.dev>"
  @readme Path.expand("../../README.md", __DIR__)
  @readme_blocks Regex.scan(~r/```elixir\n(.*?)```/s, File.read!(@readme), capture: :all_but_first)
                 |> Enum.map(fn [text] -> text end)

  setup_all do
    key = System.get_env("BILLIONSEND_E2E_API_KEY")

    if key in [nil, ""] do
      raise "BILLIONSEND_E2E_API_KEY is not set: `BILLIONSEND_E2E_API_KEY=bs_... mix e2e`"
    end

    # The contract in force is the one published now, not the snapshot.
    published = Live.fetch_spec()
    Contract.use_spec(published)
    agent = Live.start(key)

    on_exit(fn ->
      Live.cleanup(agent)
      answers = Enum.frequencies_by(Live.log(agent), fn {_, _, status} -> status end)

      IO.puts(
        "\nlive tests: #{Live.requests(agent)} requests, #{Live.sends(agent)} emails sent, " <>
          "answers #{inspect(answers)}"
      )

      leftovers = Live.leftovers(agent)

      if leftovers != [] do
        raise "left on the account, delete by hand: " <> inspect(leftovers)
      end
    end)

    {:ok, agent: agent, client: Live.client(agent), published: published, tag: Live.tag(agent)}
  end

  setup %{agent: agent} do
    on_exit(fn -> Live.cleanup(agent) end)
    :ok
  end

  # --- helpers ---------------------------------------------------------------------------

  # The answer of a call that must succeed; never shows what it holds on failure.
  defp ok!({:ok, answer}), do: answer
  defp ok!({:error, error}), do: flunk("the call failed: #{Exception.message(error)}")

  defp contract!(agent), do: Live.assert_contract(agent)

  defp address(tag, name), do: "success+#{tag}-#{name}@simulator.amazonses.com"

  defp track(agent, label, deleter), do: Live.track(agent, label, deleter)

  # A delete the test makes itself, which must succeed; cleanup then has nothing to do for it.
  defp delete!(agent, label, result) do
    assert {:ok, _} = result
    Live.forget(agent, label)
  end

  defp mail(tag, name, extra \\ %{}) do
    Map.merge(
      %{
        from: @sender,
        to: [address(tag, name)],
        subject: "sdk-e2e #{tag} #{name}",
        text: "Sent by the Elixir SDK's live tests (#{tag}).",
        html: "<p>Sent by the Elixir SDK's live tests (#{tag}).</p>"
      },
      extra
    )
  end

  defp readme_block(first_line) do
    Enum.find(@readme_blocks, &String.starts_with?(&1, first_line)) ||
      flunk("README has no block that starts with #{inspect(first_line)}")
  end

  # --- the contract itself -----------------------------------------------------------------

  @tag scenario: :contract
  test "the snapshot the SDK is built from is the published document", %{published: published} do
    # use_spec/1 replaced the snapshot with the published document; read the file instead.
    on_disk =
      Path.expand("../../openapi/api.openapi.json", __DIR__) |> File.read!() |> JSON.decode!()

    assert Live.strip_text(on_disk) == Live.strip_text(published),
           "openapi/api.openapi.json differs from https://billionsend.com/docs/api.openapi.json: run `elixir scripts/sync_openapi.exs`"

    assert map_size(published["paths"]) > 100
  end

  # --- what exists: reads only ------------------------------------------------------------

  @tag scenario: :account
  test "the account as it is: usage, health, domains, contacts, emails, statistics", %{
    agent: agent,
    client: c
  } do
    usage = ok!(BillionSend.Usage.get(c))
    assert %{"emails" => %{"daily" => %{}, "monthly" => %{}}} = usage
    assert is_map(ok!(BillionSend.Deliverability.get(c)))
    assert %{"status" => _} = ok!(BillionSend.Agent.status(c))
    assert %{"available" => available} = ok!(BillionSend.Verifications.availability(c))
    assert is_boolean(available)

    # Domains: one page, the same list walked three at a time, and walked from the middle backward.
    page = ok!(BillionSend.Domains.list(c, limit: 100))
    domains = page["data"]
    ids = Enum.map(domains, & &1["id"])
    assert page["has_more"] == false and ids != []
    assert Enum.map(BillionSend.Domains.list_all(c, limit: 3), & &1["id"]) == ids

    if length(ids) >= 6 do
      before_id = Enum.at(ids, 5)
      older = ids |> Enum.take(5) |> Enum.sort()

      walked =
        c |> BillionSend.Domains.list_all(before: before_id, limit: 2) |> Enum.map(& &1["id"])

      assert Enum.sort(walked) == older
    end

    domain = ok!(BillionSend.Domains.get(c, hd(ids)))
    assert domain["id"] == hd(ids)

    # Contacts: newest first; the stream goes on across pages.
    first = ok!(BillionSend.Contacts.list(c, limit: 2))
    assert length(first["data"]) == 2
    walked = c |> BillionSend.Contacts.list_all(limit: 2) |> Enum.take(3) |> Enum.map(& &1["id"])
    assert length(Enum.uniq(walked)) == 3

    # Emails and their statistics.
    sent = ok!(BillionSend.Emails.list(c, limit: 3))

    if sent["data"] != [],
      do: assert(is_map(ok!(BillionSend.Emails.get(c, hd(sent["data"])["id"]))))

    assert is_map(
             ok!(
               BillionSend.Emails.metrics(c, metrics: ["sent", "delivered"], granularity: "daily")
             )
           )

    assert is_map(ok!(BillionSend.Emails.Metrics.links(c, limit: 3)))

    # The other lists the account has, each answer read on real data.
    for list <- [
          fn -> BillionSend.Unsubscribes.list(c, limit: 2) end,
          fn -> BillionSend.Logs.list(c, limit: 1) end,
          fn -> BillionSend.OauthGrants.list(c, limit: 2) end,
          fn -> BillionSend.Verifications.list(c, limit: 2) end,
          fn -> BillionSend.Contacts.Imports.list(c, limit: 2) end
        ] do
      assert %{"object" => "list", "data" => data} = ok!(list.())
      assert is_list(data)
    end

    contract!(agent)
  end

  # --- what the tests create ---------------------------------------------------------------

  @tag scenario: :api_keys
  test "an API key: made, renamed, used, deleted", %{agent: agent, client: c, tag: tag} do
    created =
      ok!(BillionSend.ApiKeys.create(c, %{name: "#{tag}-key", permission: "sending_access"}))

    id = Map.fetch!(created, "id")
    track(agent, {:api_key, id}, fn -> BillionSend.ApiKeys.delete(c, id) end)
    token = Map.fetch!(created, "token")
    token_ok? = String.starts_with?(token, "bs_")
    assert token_ok?

    assert %{"id" => ^id} = ok!(BillionSend.ApiKeys.update(c, id, %{name: "#{tag}-key-renamed"}))

    # A sending-only key is refused where it may not go, with the API's error.
    restricted = Live.client(agent, api_key: token, max_retries: 0)

    case BillionSend.Usage.get(restricted) do
      {:ok, _} ->
        :ok

      {:error, %BillionSend.PermissionDeniedError{status_code: 403, name: name}} ->
        assert is_binary(name)
    end

    delete!(agent, {:api_key, id}, BillionSend.ApiKeys.delete(c, id))
    contract!(agent)
  end

  @tag scenario: :webhooks
  test "a webhook: made, changed, its secret rotated, and every secret verifies a delivery", %{
    agent: agent,
    client: c,
    tag: tag
  } do
    created =
      ok!(
        BillionSend.Webhooks.create(c, %{
          endpoint: "https://example.com/sdk-e2e",
          events: ["email.sent"]
        })
      )

    id = Map.fetch!(created, "id")
    track(agent, {:webhook, id}, fn -> BillionSend.Webhooks.delete(c, id) end)
    secret = Map.fetch!(created, "signing_secret")

    assert %{"id" => ^id} = ok!(BillionSend.Webhooks.get(c, id))

    assert {:ok, _} =
             BillionSend.Webhooks.update(c, id, %{events: ["email.sent", "email.delivered"]})

    rotated = ok!(BillionSend.Webhooks.rotate_signing_secret(c, id, %{overlap_hours: 1}))
    new_secret = Map.fetch!(rotated, "signing_secret")
    refute new_secret == secret

    # A delivery signed the way the API signs it, with the secret the API gave.
    body =
      ~s({"type":"email.sent","created_at":"2026-11-19T00:00:00.000Z","data":{"email_id":"#{tag}"}})

    sign = fn secret ->
      "whsec_" <> encoded = secret
      timestamp = System.os_time(:second)
      mac = :crypto.mac(:hmac, :sha256, Base.decode64!(encoded), "msg_#{tag}.#{timestamp}.#{body}")
      {to_string(timestamp), "v1," <> Base.encode64(mac)}
    end

    for current <- [secret, new_secret] do
      {timestamp, signature} = sign.(current)

      headers = %{
        "webhook-id" => "msg_#{tag}",
        "webhook-timestamp" => timestamp,
        "webhook-signature" => signature
      }

      assert {:ok, %{"type" => "email.sent"}} = BillionSend.verify_webhook(body, headers, current)
    end

    # During the overlap both signatures are on the header and either secret opens it.
    {timestamp, old} = sign.(secret)
    {_, new} = sign.(new_secret)

    headers = %{
      "webhook-id" => "msg_#{tag}",
      "webhook-timestamp" => timestamp,
      "webhook-signature" => old <> " " <> new
    }

    assert {:ok, _} = BillionSend.verify_webhook(body, headers, new_secret)

    assert %{"data" => []} = ok!(BillionSend.Webhooks.Events.list(c, id))
    delete!(agent, {:webhook, id}, BillionSend.Webhooks.delete(c, id))
    contract!(agent)
  end

  @tag scenario: :templates
  test "a template: made, read, changed, published, duplicated, deleted", %{
    agent: agent,
    client: c,
    tag: tag
  } do
    template = %{
      name: "#{tag}-template",
      subject: "sdk-e2e {{{NAME}}}",
      html: "<p>Hello {{{NAME}}}</p>",
      variables: [%{key: "NAME", type: "string", fallback_value: "friend"}]
    }

    id = c |> BillionSend.Templates.create(template) |> ok!() |> Map.fetch!("id")
    track(agent, {:template, id}, fn -> BillionSend.Templates.delete(c, id) end)

    assert %{"id" => ^id, "name" => name} = ok!(BillionSend.Templates.get(c, id))
    assert name == "#{tag}-template"
    assert {:ok, _} = BillionSend.Templates.update(c, id, %{subject: "sdk-e2e changed"})
    assert {:ok, _} = BillionSend.Templates.publish(c, id)

    copy = c |> BillionSend.Templates.duplicate(id) |> ok!() |> Map.fetch!("id")
    track(agent, {:template, copy}, fn -> BillionSend.Templates.delete(c, copy) end)
    refute copy == id

    delete!(agent, {:template, copy}, BillionSend.Templates.delete(c, copy))
    delete!(agent, {:template, id}, BillionSend.Templates.delete(c, id))
    contract!(agent)
  end

  @tag scenario: :contacts
  test "contacts with a segment, a topic and a property: made, found by id and by address, changed, removed",
       %{
         agent: agent,
         client: c,
         tag: tag
       } do
    segment =
      c |> BillionSend.Segments.create(%{name: "#{tag}-segment"}) |> ok!() |> Map.fetch!("id")

    track(agent, {:segment, segment}, fn -> BillionSend.Segments.delete(c, segment) end)

    topic =
      c
      |> BillionSend.Topics.create(%{
        name: "#{tag}-topic",
        default_subscription: "opt_in",
        visibility: "private"
      })
      |> ok!()
      |> Map.fetch!("id")

    track(agent, {:topic, topic}, fn -> BillionSend.Topics.delete(c, topic) end)

    property_key = "sdk_e2e_" <> String.replace(tag, ~r/\D+/, "")

    property =
      ok!(
        BillionSend.ContactProperties.create(c, %{
          key: property_key,
          type: "string",
          fallback_value: "none"
        })
      )

    property_id = Map.fetch!(property, "id")

    track(agent, {:contact_property, property_id}, fn ->
      BillionSend.ContactProperties.delete(c, property_id)
    end)

    assert {:ok, _} = BillionSend.ContactProperties.update(c, property_id, %{fallback_value: "n/a"})

    email = address(tag, "contact")
    other = [address(tag, "batch-1"), address(tag, "batch-2")]

    for e <- [email | other],
        do: track(agent, {:contact, e}, fn -> BillionSend.Contacts.delete(c, e) end)

    contact =
      ok!(
        BillionSend.Contacts.create(c, %{
          email: email,
          first_name: "SDK",
          last_name: "E2E",
          segments: [%{id: segment}],
          topics: [%{id: topic, subscription: "opt_in"}]
        })
      )

    id = Map.fetch!(contact, "id")

    # By id, and by the address itself: + and @ in a path.
    assert %{"id" => ^id, "email" => ^email, "first_name" => "SDK"} =
             ok!(BillionSend.Contacts.get(c, id))

    assert %{"id" => ^id} = ok!(BillionSend.Contacts.get(c, email))
    assert %{"id" => ^id} = ok!(BillionSend.Audiences.Contacts.get(c, segment, email))

    assert {:ok, _} = BillionSend.Contacts.update(c, id, %{first_name: "Elixir"})
    assert %{"first_name" => "Elixir"} = ok!(BillionSend.Contacts.get(c, id))

    assert %{"data" => [%{"id" => ^segment}]} = ok!(BillionSend.Contacts.Segments.list(c, id))
    # Every topic of the team is listed; ours is the one the contact was explicitly put in.
    %{"data" => topics} = ok!(BillionSend.Contacts.Topics.list(c, id))

    assert Enum.any?(
             topics,
             &(&1["id"] == topic and &1["explicit"] == true and &1["subscription"] == "opt_in")
           )

    assert {:ok, _} =
             BillionSend.Contacts.Topics.update(c, id, [%{id: topic, subscription: "opt_in"}])

    assert %{"url" => "https" <> _} = ok!(BillionSend.Contacts.preferences_link(c, id))

    assert %{"data" => [%{"id" => ^id}]} =
             ok!(BillionSend.Segments.Contacts.list(c, segment, limit: 5))

    assert {:ok, _} = BillionSend.Segments.update(c, segment, %{name: "#{tag}-segment-renamed"})
    assert {:ok, _} = BillionSend.Topics.update(c, topic, %{description: "sdk-e2e"})

    # A batch of two, read back, removed.
    batch =
      ok!(BillionSend.Contacts.Batch.create(c, Enum.map(other, &%{email: &1, first_name: "Batch"})))

    assert %{"created" => 2} = batch["counts"]

    assert %{"data" => found} =
             ok!(BillionSend.Contacts.Batch.get(c, %{contacts: Enum.map(other, &%{email: &1})}))

    assert length(found) == 2
    assert {:ok, _} = BillionSend.Contacts.Batch.remove(c, %{emails: other})
    for e <- other, do: Live.forget(agent, {:contact, e})

    assert {:ok, %{"deleted" => true}} = BillionSend.Contacts.delete(c, id)
    Live.forget(agent, {:contact, email})

    delete!(
      agent,
      {:contact_property, property_id},
      BillionSend.ContactProperties.delete(c, property_id)
    )

    delete!(agent, {:topic, topic}, BillionSend.Topics.delete(c, topic))
    delete!(agent, {:segment, segment}, BillionSend.Segments.delete(c, segment))
    contract!(agent)
  end

  @tag scenario: :suppressions
  test "manual suppressions: made one by one and in a batch, read, removed", %{
    agent: agent,
    client: c,
    tag: tag
  } do
    one = address(tag, "suppress-1")
    two = address(tag, "suppress-2")

    id =
      c
      |> BillionSend.Suppressions.create(%{email: one, origin: "manual"})
      |> ok!()
      |> Map.fetch!("id")

    track(agent, {:suppression, id}, fn -> BillionSend.Suppressions.delete(c, id) end)
    assert %{"email" => ^one, "origin" => "manual"} = ok!(BillionSend.Suppressions.get(c, id))

    %{"data" => [%{"id" => second} | _]} =
      ok!(BillionSend.Suppressions.Batch.add(c, %{emails: [two], origin: "manual"}))

    track(agent, {:suppression, second}, fn -> BillionSend.Suppressions.delete(c, second) end)

    # A domain entry has no address; it is listed with `kind`, and the harness refuses
    # any recipient at it from now on.
    blocked = "sdk-e2e-elixir-#{tag}.example"

    %{"id" => by_domain, "kind" => "domain", "email" => nil, "domain" => ^blocked} =
      ok!(BillionSend.Suppressions.create(c, %{domain: blocked}))

    track(agent, {:suppression, by_domain}, fn -> BillionSend.Suppressions.delete(c, by_domain) end)

    assert %{"data" => listed} = ok!(BillionSend.Suppressions.list(c, kind: "domain", limit: 100))
    assert Enum.any?(listed, &(&1["id"] == by_domain and &1["removable"] == true))

    assert {:ok, %{"deleted" => true}} = BillionSend.Suppressions.delete(c, by_domain)
    assert {:ok, %{"deleted" => true}} = BillionSend.Suppressions.delete(c, second)
    assert {:ok, %{"deleted" => true}} = BillionSend.Suppressions.delete(c, id)
    Live.forget(agent, {:suppression, by_domain})
    Live.forget(agent, {:suppression, second})
    Live.forget(agent, {:suppression, id})
    contract!(agent)
  end

  @tag scenario: :events
  test "a custom event and a disabled automation: made, validated, simulated, read, removed", %{
    agent: agent,
    client: c,
    tag: tag
  } do
    event_name = "#{tag}-event"
    event = c |> BillionSend.Events.create(%{name: event_name}) |> ok!() |> Map.fetch!("id")
    track(agent, {:event, event}, fn -> BillionSend.Events.remove(c, event) end)
    assert %{"id" => ^event, "name" => ^event_name} = ok!(BillionSend.Events.get(c, event_name))

    flow = %{
      steps: [
        %{key: "start", type: "trigger", config: %{event_name: event_name}},
        %{key: "pause", type: "delay", config: %{duration: "1 hour"}}
      ],
      connections: [%{from: "start", to: "pause"}]
    }

    assert %{"valid" => true} = ok!(BillionSend.Automations.validate(c, flow))

    automation =
      c
      |> BillionSend.Automations.create(
        Map.merge(flow, %{name: "#{tag}-automation", status: "disabled"})
      )
      |> ok!()
      |> Map.fetch!("id")

    track(agent, {:automation, automation}, fn -> BillionSend.Automations.remove(c, automation) end)

    assert %{"id" => ^automation, "status" => "disabled"} =
             ok!(BillionSend.Automations.get(c, automation))

    assert {:ok, _} =
             BillionSend.Automations.update(c, automation, %{name: "#{tag}-automation-renamed"})

    # Worked out without running anything, for an address that is not a contact.
    simulated =
      ok!(
        BillionSend.Automations.simulate(c, automation, %{
          contact: %{email: address(tag, "simulated")}
        })
      )

    assert simulated["status"] in ["completed", "failed"]

    copy = c |> BillionSend.Automations.duplicate(automation) |> ok!() |> Map.fetch!("id")
    track(agent, {:automation, copy}, fn -> BillionSend.Automations.remove(c, copy) end)

    assert %{"automation_id" => ^automation} = ok!(BillionSend.Automations.metrics(c, automation))
    assert %{"data" => []} = ok!(BillionSend.Automations.Runs.list(c, automation))

    # Sending the event reaches no automation that is enabled: none listens to this name.
    email = address(tag, "event-contact")
    track(agent, {:contact, email}, fn -> BillionSend.Contacts.delete(c, email) end)
    contact = ok!(BillionSend.Contacts.create(c, %{email: email}))

    sent =
      ok!(
        BillionSend.Events.send(c, %{
          event: event_name,
          contact_id: contact["id"],
          payload: %{"source" => "sdk-e2e"}
        })
      )

    assert sent["event"] == event_name

    delete!(agent, {:contact, email}, BillionSend.Contacts.delete(c, email))
    delete!(agent, {:automation, copy}, BillionSend.Automations.remove(c, copy))
    delete!(agent, {:automation, automation}, BillionSend.Automations.remove(c, automation))
    delete!(agent, {:event, event}, BillionSend.Events.remove(c, event))
    contract!(agent)
  end

  @tag scenario: :emails
  test "email: sent once with a key, read, with an attachment, in a batch, scheduled and cancelled, shared",
       %{agent: agent, client: c, tag: tag} do
    key = "#{tag}-send"
    Live.count_send(agent)

    id =
      c
      |> BillionSend.Emails.send(mail(tag, "one"), idempotency_key: key)
      |> ok!()
      |> Map.fetch!("id")

    # The same key again is the same email, not a second one.
    assert %{"id" => ^id} = ok!(BillionSend.Emails.send(c, mail(tag, "one"), idempotency_key: key))

    assert %{"id" => ^id, "from" => _, "to" => [_]} = ok!(BillionSend.Emails.get(c, id))

    # Insights are there only for some emails: an answer, or the API's 404.
    case BillionSend.Emails.insights(c, id) do
      {:ok, insights} -> assert insights["email_id"] == id
      {:error, %BillionSend.NotFoundError{}} -> :ok
    end

    # An attachment, listed and read.
    Live.count_send(agent)

    attachment = %{
      filename: "sdk-e2e.txt",
      content: Base.encode64("hello from the Elixir SDK"),
      content_type: "text/plain"
    }

    with_file =
      c
      |> BillionSend.Emails.send(mail(tag, "file", %{attachments: [attachment]}))
      |> ok!()
      |> Map.fetch!("id")

    listed = ok!(BillionSend.Emails.Attachments.list(c, with_file))
    assert [%{"id" => attachment_id, "filename" => "sdk-e2e.txt"}] = listed["data"]

    assert %{"id" => ^attachment_id, "download_url" => "https" <> _} =
             ok!(BillionSend.Emails.Attachments.get(c, with_file, attachment_id))

    # Two in a batch, one answer each.
    Live.count_send(agent, 2)
    batch = ok!(BillionSend.Emails.batch(c, [mail(tag, "batch-1"), mail(tag, "batch-2")]))
    assert length(batch["data"]) == 2

    # Scheduled for the future, moved, cancelled: it never goes out.
    Live.count_send(agent)
    later = DateTime.utc_now() |> DateTime.add(2 * 86_400) |> DateTime.to_iso8601()
    even_later = DateTime.utc_now() |> DateTime.add(3 * 86_400) |> DateTime.to_iso8601()

    scheduled =
      c
      |> BillionSend.Emails.send(mail(tag, "later", %{scheduled_at: later}))
      |> ok!()
      |> Map.fetch!("id")

    assert {:ok, _} = BillionSend.Emails.update(c, scheduled, %{scheduled_at: even_later})
    assert {:ok, %{"id" => ^scheduled}} = BillionSend.Emails.cancel(c, scheduled)

    # A link to the email, and its withdrawal.
    assert %{"url" => "https" <> _} = ok!(BillionSend.Emails.share(c, id, %{expires_in: "1 hour"}))
    assert {:ok, %{"id" => ^id}} = BillionSend.Emails.unshare(c, id)
    contract!(agent)
  end

  @tag scenario: :broadcasts
  test "a broadcast draft: made, read, changed, duplicated, its audience read, deleted", %{
    agent: agent,
    client: c,
    tag: tag
  } do
    segment =
      c
      |> BillionSend.Segments.create(%{name: "#{tag}-broadcast-segment"})
      |> ok!()
      |> Map.fetch!("id")

    track(agent, {:segment, segment}, fn -> BillionSend.Segments.delete(c, segment) end)

    draft = %{
      name: "#{tag}-broadcast",
      from: @sender,
      subject: "sdk-e2e draft",
      html: "<p>Never sent.</p>",
      segment_id: segment
    }

    id = c |> BillionSend.Broadcasts.create(draft) |> ok!() |> Map.fetch!("id")
    track(agent, {:broadcast, id}, fn -> BillionSend.Broadcasts.delete(c, id) end)

    assert %{"id" => ^id, "status" => "draft"} = ok!(BillionSend.Broadcasts.get(c, id))
    assert {:ok, _} = BillionSend.Broadcasts.update(c, id, %{subject: "sdk-e2e draft, changed"})

    copy = c |> BillionSend.Broadcasts.duplicate(id) |> ok!() |> Map.fetch!("id")
    track(agent, {:broadcast, copy}, fn -> BillionSend.Broadcasts.delete(c, copy) end)

    assert %{"data" => []} = ok!(BillionSend.Broadcasts.recipients(c, id, type: "sent"))
    assert %{"data" => []} = ok!(BillionSend.Broadcasts.clicked_links(c, id))

    delete!(agent, {:broadcast, copy}, BillionSend.Broadcasts.delete(c, copy))
    delete!(agent, {:broadcast, id}, BillionSend.Broadcasts.delete(c, id))
    delete!(agent, {:segment, segment}, BillionSend.Segments.delete(c, segment))
    contract!(agent)
  end

  @tag scenario: :errors
  test "the API's errors come back as the SDK's", %{agent: agent, client: c} do
    missing = "00000000-0000-4000-8000-0000000000e2"

    assert {:error,
            %BillionSend.NotFoundError{
              status_code: 404,
              name: name,
              message: message,
              request_id: request_id
            }} =
             BillionSend.Domains.get(c, missing)

    assert is_binary(name) and is_binary(message)
    assert is_binary(request_id) and request_id != ""

    # A request the document forbids (a malformed address), sent on purpose.
    unchecked = Live.client(agent, unchecked: true, max_retries: 0)

    assert {:error, %BillionSend.ValidationError{status_code: status}} =
             BillionSend.Contacts.create(unchecked, %{email: "not-an-address"})

    assert status in [400, 422]

    refused = Live.client(agent, api_key: "bs_not_a_real_key_sdk_e2e", max_retries: 0)

    assert {:error, %BillionSend.AuthenticationError{status_code: 401}} =
             BillionSend.Domains.list(refused)

    assert_raise BillionSend.NotFoundError, fn -> BillionSend.Domains.get!(c, missing) end
    contract!(agent)
  end

  # --- the README's examples, run as written ----------------------------------------------
  #
  # Only what has to differ is changed, and each change is a replacement written out
  # here: the client is the live one (throttled and checked), the mail goes from the
  # test sender to the simulator, and the loop over every contact is cut to three.

  defp live_text(block) do
    block
    |> String.replace("BillionSend.client()", "BillionSend.Test.Live.client(agent)")
    |> String.replace("Acme <hello@acme.dev>", @sender)
  end

  # The README's recipient is an example address; the live run sends to the simulator instead.
  defp to_simulator(text, tag) do
    Regex.replace(~r/to: \[[^\]]*\]/, text, ~s(to: ["#{address(tag, "readme")}"]))
  end

  defp only_simulator!(text) do
    recipients = Regex.scan(~r/to: \[([^\]]*)\]/, text, capture: :all_but_first) |> List.flatten()
    assert recipients != []

    assert Enum.all?(recipients, &String.contains?(&1, "@simulator.amazonses.com")),
           "a README example sends to #{inspect(recipients)}"

    text
  end

  @tag scenario: :readme
  test "README: quick start, a send with a key of its own, paging, the error block", %{
    agent: agent,
    client: c,
    tag: tag
  } do
    binding = [agent: agent]

    # Quick start: the README's recipient becomes a simulator address, and nothing else may be one.
    quick =
      "client = BillionSend.client()  # reads BILLIONSEND_API_KEY"
      |> readme_block()
      |> live_text()
      |> to_simulator(tag)
      |> only_simulator!()

    Live.count_send(agent)
    output = capture_io(fn -> Code.eval_string(quick, binding) end)
    assert String.trim(output) =~ ~r/\A[0-9a-f-]{36}\z/

    # Sending once, with the README's own key shape.
    Live.count_send(agent)
    send_once = readme_block("BillionSend.Emails.send(client, message, idempotency_key:")
    message = mail(tag, "readme")
    {first, _} = Code.eval_string(send_once, client: c, message: message, user: %{id: tag})
    {second, _} = Code.eval_string(send_once, client: c, message: message, user: %{id: tag})
    assert ok!(first)["id"] == ok!(second)["id"]

    # Paging: the README's loop over every contact, cut to the first three (its output dropped).
    paging =
      "client\n|> BillionSend.Contacts.list_all"
      |> readme_block()
      |> String.replace("|> Enum.each(", "|> Enum.take(3)\n|> Enum.each(")

    capture_io(fn ->
      {_, paged} = Code.eval_string(paging, client: c)
      send(self(), {:paged, paged[:first_ten]})
    end)

    assert_received {:paged, first_ten}
    assert length(first_ten) in 1..10

    # The error block, on a domain that is not there.
    errors = "require Logger\n" <> readme_block("case BillionSend.Domains.get(client,")
    assert {nil, _} = Code.eval_string(errors, client: c)

    contract!(agent)
  end

  @tag scenario: :readme
  test "README: a CSV import, read until it is done, and the contact it made removed", %{
    agent: agent,
    client: c,
    tag: tag
  } do
    email = address(tag, "import")
    track(agent, {:contact, email}, fn -> BillionSend.Contacts.delete(c, email) end)

    dir = Path.join(System.tmp_dir!(), "billionsend-e2e-#{tag}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "contacts.csv"), "Email,First Name\r\n#{email},Ada\r\n")
    cwd = File.cwd!()

    try do
      File.cd!(dir)
      {_, binding} = Code.eval_string(readme_block("{:ok, upload} ="), client: c)
      upload = binding[:upload]
      assert upload["object"] == "contact_import"

      done =
        Enum.reduce_while(1..4, upload, fn _, current ->
          if current["status"] in ["completed", "failed"],
            do: {:halt, current},
            else: {:cont, ok!(BillionSend.Contacts.Imports.get(c, current["id"]))}
        end)

      assert done["status"] == "completed"
      assert %{"total" => 1} = done["counts"]
    after
      File.cd!(cwd)
      File.rm_rf!(dir)
    end

    assert %{"email" => ^email, "first_name" => "Ada"} = ok!(BillionSend.Contacts.get(c, email))
    assert {:ok, %{"deleted" => true}} = BillionSend.Contacts.delete(c, email)
    Live.forget(agent, {:contact, email})
    contract!(agent)
  end

  # --- the account is as it was --------------------------------------------------------------

  @tag scenario: :sweep
  test "nothing the live tests created is left, from this run or an earlier one", %{
    agent: agent,
    client: c
  } do
    Live.cleanup(agent)

    # Everything the tests make is named with sdk-e2e-elixir- (a webhook's endpoint, a
    # property's key and a contact's address carry it in their own way); the newest of
    # each kind is on the first page. What a call that timed out may have created
    # without the test learning its id is found here.
    lists = [
      {"segments", fn -> BillionSend.Segments.list(c, limit: 100) end, & &1["name"],
       "sdk-e2e-elixir-", &BillionSend.Segments.delete(c, &1["id"])},
      {"topics", fn -> BillionSend.Topics.list(c) end, & &1["name"], "sdk-e2e-elixir-",
       &BillionSend.Topics.delete(c, &1["id"])},
      {"contact properties", fn -> BillionSend.ContactProperties.list(c, limit: 100) end,
       & &1["key"], "sdk_e2e_", &BillionSend.ContactProperties.delete(c, &1["id"])},
      {"templates", fn -> BillionSend.Templates.list(c, limit: 100) end, & &1["name"],
       "sdk-e2e-elixir-", &BillionSend.Templates.delete(c, &1["id"])},
      {"webhooks", fn -> BillionSend.Webhooks.list(c, limit: 100) end, & &1["endpoint"],
       "example.com/sdk-e2e/", &BillionSend.Webhooks.delete(c, &1["id"])},
      {"API keys", fn -> BillionSend.ApiKeys.list(c, limit: 100) end, & &1["name"],
       "sdk-e2e-elixir-", &BillionSend.ApiKeys.delete(c, &1["id"])},
      {"broadcasts", fn -> BillionSend.Broadcasts.list(c, limit: 100) end, & &1["name"],
       "sdk-e2e-elixir-", &BillionSend.Broadcasts.delete(c, &1["id"])},
      {"automations", fn -> BillionSend.Automations.list(c, limit: 100) end, & &1["name"],
       "sdk-e2e-elixir-", &BillionSend.Automations.remove(c, &1["id"])},
      {"events", fn -> BillionSend.Events.list(c, limit: 100) end, & &1["name"], "sdk-e2e-elixir-",
       &BillionSend.Events.remove(c, &1["id"])},
      {"suppressions", fn -> BillionSend.Suppressions.list(c, limit: 100, kind: "all") end,
       &(&1["email"] || &1["domain"]), "sdk-e2e-elixir-",
       &BillionSend.Suppressions.delete(c, &1["id"])},
      {"contacts", fn -> BillionSend.Contacts.list(c, limit: 100) end, & &1["email"],
       "sdk-e2e-elixir-", &BillionSend.Contacts.delete(c, &1["id"])}
    ]

    left =
      for {name, list, name_of, marker, delete} <- lists,
          found =
            Enum.filter(ok!(list.())["data"], &String.contains?(to_string(name_of.(&1)), marker)),
          found != [] do
        # Removed, so that the account is clean, and reported, so that the cause is looked at.
        for item <- found, do: delete.(item)
        {name, Enum.map(found, & &1["id"])}
      end

    assert left == [], "left on the account (now deleted): #{inspect(left)}"
    assert Live.leftovers(agent) == []
    contract!(agent)
  end

  # --- what is not tested live, and why --------------------------------------------------------
  #
  #   * domains.create / update / delete / verify and domains.claims.*: a domain is a real
  #     SES identity (the account's eight are only read).
  #   * broadcasts.send, broadcasts.cancel: a broadcast reaches the audience it names.
  #   * webhooks.events.get / replay / attempts.list: a new webhook has no events; the
  #     list is read, the rest needs a delivery to exist.
  #   * automations.stop / runs.get / runs.cancel: nothing runs (only disabled drafts are made).
  #   * oauthGrants.revoke, apiKeys of the account, verifications.create / estimate:
  #     they change or spend the account's own state.
  #   * unsubscribes.create: an opt-out is permanent, with no way back for the account.
  #   * every inboxes.* and emails.receiving.* operation, agent.signup, agent.claimEmail,
  #     and the README's inbox, signup and event-stream examples: they create an inbox or
  #     an account, or open a stream on the real team (offline: test/readme_test.exs).
  #   * the README's webhook controller: it needs a delivery; the signature check itself is
  #     run above with the secrets the API produced.
  #   * large uploads and a lost connection: a test that sends real traffic cannot make them
  #     happen; offline, over real sockets (test/wire_test.exs).
end
