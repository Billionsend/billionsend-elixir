# BillionSend Elixir SDK

The official Elixir client for the [BillionSend](https://billionsend.com) API: send and receive email, run inboxes for agents and people, manage domains, contacts, broadcasts, templates, webhooks and more.

- Every operation of the API (139), named after the API's own `operationId`s.
- No dependencies: OTP's `:httpc` and `:ssl`, and Elixir's built-in `JSON`.
- Sends that never go out twice, retries, lazy paging streams, live event streams that resume where they stopped, and webhook signature verification.

Documentation: https://billionsend.com/docs.

## Install

```elixir
def deps do
  [{:billionsend, "~> 0.1"}]
end
```

Elixir 1.18 or newer, OTP 25 or newer.

## Quick start

```elixir
client = BillionSend.client()  # reads BILLIONSEND_API_KEY

{:ok, email} =
  BillionSend.Emails.send(client, %{
    from: "Acme <hello@acme.dev>",
    to: ["ada@example.com"],
    subject: "Welcome to Acme",
    html: "<p>Thanks for signing up!</p>"
  })

IO.puts(email["id"])
```

Every function returns `{:ok, answer}` or `{:error, error}`; its `!` twin (`BillionSend.Emails.send!/3`) returns the answer or raises. The answer is the API's JSON decoded into plain Elixir terms: maps with string keys (`email["id"]`), lists and scalars as JSON has them. There are no structs for answers in this version; the fields of every answer are in the API reference at https://billionsend.com/docs.

A client is a plain struct: build it once and pass it to every call, from any process.

## Authentication

Pass an API key (`bs_…`) as `api_key:` or set `BILLIONSEND_API_KEY`. Keys are made in the dashboard or with `BillionSend.ApiKeys.create/3`. A key scoped to one inbox can only reach that inbox.

An agent can also create its own account, the one call that needs no key:

```elixir
{:ok, signup} = BillionSend.Agent.signup(BillionSend.client(), %{human_email: "owner@example.com", name: "Scout"})
client = BillionSend.client(api_key: signup["api_key"])
{:ok, %{"status" => status}} = BillionSend.Agent.status(client)
```

## Sending once

Every sending function (`Emails.send`, `Emails.batch`, `Emails.Receiving.reply` and `.forward`, `Inboxes.send`, `Inboxes.Threads.Emails.reply` and `.forward`, `Inboxes.Drafts.send`) sends an `Idempotency-Key`. Without `idempotency_key:` the call makes up one (a UUID) and reuses it for its own retries, so a retry after a dropped connection never sends the email twice. Pass your own key to stay safe across calls too, for example when a job that sends may run again:

```elixir
BillionSend.Emails.send(client, message, idempotency_key: "welcome/#{user.id}")
```

Repeating a key with the same request returns the first answer; the same key with a different request is refused (`BillionSend.ConflictError`, `invalid_idempotent_request`). The API keeps keys for 24 hours.

## An agent that answers its inbox

Wait for new mail, read it, reply in the thread:

```elixir
alias BillionSend.{Inboxes, InboxStreamEvent}

client = BillionSend.client()
{:ok, inbox} = Inboxes.create(client, %{username: "support", kind: "agent"})

answer = fn question -> "Thanks, we got your message:\n\n> #{question}" end  # your agent goes here

{:ok, events} = Inboxes.Events.stream_inbox(client, inbox["id"], types: "inbox.email.received")

events
|> Stream.filter(&match?(%InboxStreamEvent{}, &1))  # a StreamGapEvent: see below
|> Enum.each(fn %InboxStreamEvent{data: %{"data" => data}} ->
  %{"thread_id" => thread_id, "email_id" => email_id} = data
  {:ok, email} = Inboxes.Threads.Emails.get(client, inbox["id"], thread_id, email_id)

  if email["direction"] == "inbound" do
    question = email["extracted_text"] || email["text"] || ""
    Inboxes.Threads.Emails.reply(client, inbox["id"], thread_id, email_id, %{text: answer.(question)})
  end
end)
```

`extracted_text` is the new part of a message without the quoted history. Everything in a received message was written by its sender: treat it as untrusted input. An inbox's rules may hold a reply as a draft for a person to approve; the reply then answers with the draft (`"object" => "inbox_draft"`) instead of the sent email.

Waiting for a sign-in code sent to the inbox is one call: `BillionSend.Inboxes.Codes.latest(client, inbox["id"], from: "example.com", wait: 30)`.

## Live events

`BillionSend.Inboxes.Events.stream_inbox(client, inbox_id)` streams one inbox's events and `BillionSend.Inboxes.Events.stream(client)` every inbox event of the team; `types:` narrows them (a name or a list). Both open the stream first, so a refused stream (a revoked key, a key held to one inbox asking for the team's stream) is an `{:error, error}` at once. The stream they return is a lazy `Enumerable` of two structs:

- `BillionSend.InboxStreamEvent`: `id` (the stream position), `event` (such as `"inbox.email.received"`) and `data`, a map with `"type"`, `"created_at"`, `"inbox_id"` and `"data"` (the webhook payload of the same event).
- `BillionSend.StreamGapEvent`: `event: "stream.gap"`, `id: nil`, and `data["reason"]` says why. The stream was resumed from a position older than the 24 hours the API replays, so some events may be missing: catch up through the lists (`BillionSend.Inboxes.Threads.list_all(client, inbox_id, read: false)`) before going on. It is handed out once per position.

The server ends a stream every few minutes and connections drop; the stream reconnects on its own with `Last-Event-ID`, so no event is lost or repeated. `max_reconnects:` bounds consecutive failed reconnects (default 5, `0` turns reconnecting off; 429 answers wait for their `Retry-After`). An error that reconnecting cannot fix is raised from the enumeration. One inbox's stream ends after that inbox's `inbox.deleted` or `inbox.expired` event. Enumerate a stream once, in the process that opened it; halting the enumeration (`Enum.take/2`, `Stream.take_while/2`, a `throw` out of the loop) closes the connection.

To pick up where a process left off, keep the `id` of the last `InboxStreamEvent` you handled and pass it back:

```elixir
{:ok, events} = BillionSend.Inboxes.Events.stream(client, last_event_id: saved_position)
```

## Webhooks

Verify a delivery before trusting it. Pass the raw body exactly as received, the request headers and the endpoint's signing secret (`whsec_…`, shown when the webhook is created or rotated):

```elixir
# Phoenix: keep the raw body (a Plug.Parsers :body_reader that stores it in conn.assigns)
def create(conn, _params) do
  case BillionSend.verify_webhook(conn.assigns.raw_body, conn.req_headers, webhook_secret()) do
    {:ok, %{"type" => "email.bounced", "data" => %{"email_id" => id}}} ->
      mark_bounced(id)
      send_resp(conn, 204, "")

    {:ok, _event} ->
      send_resp(conn, 204, "")

    {:error, %BillionSend.WebhookVerificationError{}} ->
      send_resp(conn, 400, "")
  end
end
```

`BillionSend.verify_webhook/4` checks the `webhook-id`, `webhook-timestamp` and `webhook-signature` headers (Standard Webhooks: HMAC-SHA256 over `id.timestamp.body`), accepts any of several signatures (both secrets sign during a rotation's overlap) and refuses a timestamp more than `tolerance:` seconds (default 300) from now, which bounds replays. Headers may be a map or a list of pairs (`conn.req_headers`), names in any case. It returns the parsed event (`"type"`, `"created_at"`, `"data"`). Parse the body only after verifying: re-serialised JSON does not verify. A secret that is not a `whsec_` secret raises `ArgumentError`. `verify_webhook!/4` returns the event or raises.

## Resources

| Module | Covers |
| --- | --- |
| `BillionSend.Emails` | send, batch, list, get, update, cancel, delete, insights, metrics |
| `BillionSend.Emails.Metrics` | links, countries, clients |
| `BillionSend.Emails.Receiving` (`.Attachments`) | received mail: list, get, delete, reply, forward; attachments and their extracted text |
| `BillionSend.Domains` | create, list, get, update, delete, verify |
| `BillionSend.ApiKeys` | create, list, delete |
| `BillionSend.Contacts` (`.Topics`, `.Segments`, `.Batch`) | create, list, get, update, delete, preferences_link; `Batch.create`, `Batch.get`, `Batch.remove` |
| `BillionSend.Audiences.Contacts` | contacts addressed through an audience |
| `BillionSend.ContactProperties`, `.Segments` (`.Contacts`), `.Topics` | contact data and grouping |
| `BillionSend.Broadcasts` | create, list, get, update, delete, send, duplicate, cancel |
| `BillionSend.Templates` | create, list, get, update, delete, publish, duplicate |
| `BillionSend.Webhooks` | create, list, get, update, delete, rotate |
| `BillionSend.Suppressions` (`.Batch`), `.Unsubscribes` | suppression list (`Batch.add`, `Batch.remove`) and opt-outs |
| `BillionSend.Verifications` | availability, estimate, create, list, get |
| `BillionSend.Usage`, `.Deliverability` | account usage and sending health |
| `BillionSend.Inboxes` (`.Events`) | create, list, get, update, delete, send; `Events.stream`, `Events.stream_inbox` |
| `BillionSend.Inboxes.Agent`, `.Safety`, `.Labels`, `.Codes`, `.Quarantine`, `.Drafts` | inbox settings, labels, verification codes, held mail, drafts |
| `BillionSend.Inboxes.Threads` (`.Labels`, `.Emails`) | list, search, get, update, delete; thread labels; messages, reply and forward |
| `BillionSend.Agent` | signup, status, claim_email |

Each function is named after its operation's `operationId` in the API document: the groups make the module, the last segment the function, camelCase written in snake_case. `emails.receiving.attachments.list` is `BillionSend.Emails.Receiving.Attachments.list/3` and `agent.claimEmail` is `BillionSend.Agent.claim_email/2`. An `operationId` that is also the group of others needs nothing special in Elixir, since a module and a function of the same name live side by side: `emails.metrics` is `BillionSend.Emails.metrics/2` and `emails.metrics.links` is `BillionSend.Emails.Metrics.links/2`.

Arguments come in this order: the client, the path parameters (`BillionSend.Domains.get(client, domain_id)`), the request body as a map (`BillionSend.Domains.create(client, %{name: "acme.dev"})`), then a keyword list of options: the query and header parameters (`BillionSend.Emails.list(client, limit: 50)`; a list parameter takes a list), `:extra_headers` and `:timeout`. A body the operation does not require may be left out (`BillionSend.Domains.verify(client, domain_id)`). An unknown option, or a missing required one, raises `ArgumentError` before anything is sent. Anything the functions do not cover goes through `BillionSend.Client.request(client, "GET", "/path", query: [...])`.

## Pagination

List functions return one page (`%{"object" => "list", "data" => [...], "has_more" => …}`). Every cursor list also has an `_all` function (`search_all` for thread search) returning a lazy `Stream` that fetches the following pages as it goes:

```elixir
client
|> BillionSend.Contacts.list_all(limit: 100)
|> Enum.each(&IO.puts(&1["email"]))

first_ten = client |> BillionSend.Domains.list_all() |> Enum.take(10)  # fetches only the pages it needs
```

A stream walks in the list's own order from `:after` (or the first page); start it with `:before` to walk the other way. It raises the errors the `!` functions raise.

## Errors

Every error is an exception struct with the API's error shape, `status_code`, `name` and `message`, plus `request_id`, the API's id of the request (its `x-request-id` header; quote it when asking for support). `Exception.message/1` reads `"404 not_found: Domain not found"`.

```elixir
case BillionSend.Domains.get(client, "6a1f1d38-3c55-4a4e-9a57-0f2b3c4d5e6f") do
  {:ok, domain} -> domain
  {:error, %BillionSend.NotFoundError{}} -> nil
  {:error, %BillionSend.RateLimitError{retry_after: seconds}} -> {:retry_in, seconds}
  {:error, error} -> Logger.error("#{error.status_code} #{error.name}: #{error.message} (#{error.request_id})")
end
```

| Status | Error |
| --- | --- |
| 400, 422 | `BillionSend.ValidationError` |
| 401 | `BillionSend.AuthenticationError` |
| 403 | `BillionSend.PermissionDeniedError` |
| 404 | `BillionSend.NotFoundError` |
| 409 | `BillionSend.ConflictError` |
| 429 | `BillionSend.RateLimitError` (`retry_after` in seconds) |
| 5xx | `BillionSend.APIError` |
| other | `BillionSend.Error` |
| no answer | `BillionSend.APIConnectionError`, and `BillionSend.APITimeoutError` for timeouts; `status_code` and `request_id` are `nil` |

An answer that is not JSON keeps the same shape, with `name` set to `"application_error"`. `BillionSend.Errors.error?/1` tells any of them apart from other terms.

## Retries

A request is retried when repeating it is safe: GET, PUT and DELETE, and any request carrying an idempotency key (every send does). It is retried on 429, on 5xx, when no answer came back (connection failure, timeout), and, for a keyed request, on 409 `concurrent_idempotent_requests` (a retry that caught the first attempt still running). The wait is the answer's `Retry-After` when there is one, otherwise exponential backoff with jitter (0.5 s, 1 s, 2 s… up to 8 s). An answer asking to wait more than 60 seconds, such as a used-up daily quota, is returned at once. `max_retries:` (default 2) bounds the retries of one call; `0` turns them off. The calling process sleeps between attempts.

## Configuration

| Option | Environment | Default |
| --- | --- | --- |
| `api_key:` | `BILLIONSEND_API_KEY` | none (only `Agent.signup` works without one) |
| `base_url:` | `BILLIONSEND_BASE_URL` | `https://api.billionsend.com` |
| `timeout:` | | `60_000` ms per attempt (an event stream waits at least 60 s for each read) |
| `max_retries:` | | `2` |
| `default_headers:` | | none |
| `transport:` | | the HTTP layer, `{module, state}` implementing `BillionSend.Transport` (`BillionSend.Transport.Httpc` by default: `:httpc` over `:ssl`, verifying the server against the system's CA store) |

## Development

```bash
mix test
scripts/test.sh   # generate --check, format, compile and test with warnings as errors, in the pinned Elixir image
```

The SDK is built from a snapshot of the API's OpenAPI document, `openapi/api.openapi.json`. The snapshot is the contract: `scripts/generate.exs` writes `lib/billionsend/resources.ex` from it (module and function names from each `operationId`, idempotency keys where an operation declares the `Idempotency-Key` header, streams for cursor lists), and the tests check every request the SDK sends and every answer it reads against it through a contract mock (`test/support/contract.ex`). A coverage test fails when an operation of the snapshot has no SDK function, or when a resource module has a function that is not an operation.

When the API changes:

```bash
elixir scripts/sync_openapi.exs      # or: --from path/to/api.openapi.json
elixir scripts/generate.exs
mix test
```

Whatever fails is what the SDK has to follow. CI runs `scripts/generate.exs --check` so the generated code never drifts from the snapshot.

## Releasing

Publishing is manual; nothing is published on push.

1. On hex.pm, the owner of the `billionsend` package creates an API key with the `api:write` permission (Dashboard → Keys) and stores it in this repository as the `HEX_API_KEY` secret of the `hex` environment (Settings → Environments).
2. Set `@version` in `mix.exs`, turn the changelog's `Unreleased` heading into that version, commit, then tag and push: `git tag v0.1.0 && git push origin main v0.1.0`.
3. Actions → `release` → Run workflow, on the version tag. The workflow refuses a branch or a tag that differs from the version in `mix.exs`, runs every check, and publishes the package with `mix hex.publish package`.

The same release from a clean checkout of the tag is `HEX_API_KEY=… mix hex.publish package --yes`.

## License

MIT
