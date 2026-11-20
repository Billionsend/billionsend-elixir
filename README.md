# BillionSend Elixir SDK

The official Elixir client for the [BillionSend](https://billionsend.com) API: send and receive email, run inboxes for agents and people, manage domains, contacts, broadcasts, templates, webhooks and more.

- Every operation of the API (186), named after the API's own `operationId`s.
- No dependencies: OTP's `:httpc` and `:ssl`, and Elixir's built-in `JSON`.
- Sends that never go out twice, retries, lazy paging streams, live event streams that resume where they stopped, and webhook signature verification.

Documentation: https://billionsend.com/docs.

## Install

```elixir
def deps do
  [{:billionsend, "~> 0.3"}]
end
```

Elixir 1.18 or newer, OTP 25 or newer.

## Quick start

```elixir
client = BillionSend.client()  # reads BILLIONSEND_API_KEY

{:ok, email} =
  BillionSend.Emails.send(client, %{
    from: "Acme <hello@acme.dev>",
    to: ["success@simulator.amazonses.com"],
    subject: "Welcome to Acme",
    html: "<p>Thanks for signing up!</p>"
  })

IO.puts(email["id"])
```

Every function returns `{:ok, answer}` or `{:error, error}`; its `!` twin (`BillionSend.Emails.send!/3`) returns the answer or raises. The answer is the API's JSON decoded into plain Elixir terms: maps with string keys (`email["id"]`), lists and scalars as JSON has them. There are no structs for answers in this version; the fields of every answer are in the API reference at https://billionsend.com/docs.

A client is a plain struct: build it once and pass it to every call, from any process.

## Authentication

Pass an API key (`bs_…`) as `api_key:` or set `BILLIONSEND_API_KEY`; whitespace around it, such as the newline a file read leaves, is dropped. Keys are made in the dashboard or with `BillionSend.ApiKeys.create/3`. A key scoped to one inbox can only reach that inbox.

An agent can also create its own account, the one call that needs no key:

```elixir
{:ok, signup} = BillionSend.Agent.signup(BillionSend.client(), %{human_email: "owner@example.com", name: "Scout"})
client = BillionSend.client(api_key: signup["api_key"])
{:ok, %{"status" => status}} = BillionSend.Agent.status(client)
```

## Sending once

Every sending function (`Emails.send`, `Emails.batch`, `Emails.Receiving.reply` and `.forward`, `Inboxes.send`, `Inboxes.Threads.Emails.reply` and `.forward`, `Inboxes.Drafts.send`, `Events.send`) sends an `Idempotency-Key`. Without `idempotency_key:` the call makes up one (a UUID) and reuses it for its own retries, so a retry after a dropped connection never sends the email twice. Pass your own key to stay safe across calls too, for example when a job that sends may run again:

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
# A StreamGapEvent: see below. An inbox's own stream also carries inbox.deleted and
# inbox.expired whatever `types:` says, so keep only the mail.
|> Stream.filter(&match?(%InboxStreamEvent{event: "inbox.email.received"}, &1))
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

The server ends a stream every few minutes and connections drop; the stream reconnects on its own with `Last-Event-ID`, so no event is lost or repeated. Before reconnecting it waits a second (or what the server's `retry` field asks). A connection that opens starts the count again, so a quiet inbox that gets only keepalives keeps its stream however long it waits; A reconnect the API answers with a 429 or 5xx waits what its `Retry-After` asks (one over 60 seconds raises that error at once). `max_reconnects:` (default 5) bounds the reconnects in a row that fail to open: past it, the enumeration raises the API's error for the last one (`BillionSend.RateLimitError`, `BillionSend.APIError`), or `BillionSend.APIConnectionError` ("gave up after N reconnects") when it got no answer. A reconnect the API refuses for good, such as a revoked key, raises its own error. One inbox's stream always carries that inbox's `inbox.deleted` and `inbox.expired` events, whatever `types:` names, and ends after one of them. Enumerate a stream once, in the process that opened it; halting the enumeration (`Enum.take/2`, `Stream.take_while/2`, a `throw` out of the loop) closes the connection.

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

`BillionSend.verify_webhook/4` checks the `webhook-id`, `webhook-timestamp` and `webhook-signature` headers (Standard Webhooks: HMAC-SHA256 over `id.timestamp.body`), accepts any of several signatures (both secrets sign during a rotation's overlap) and refuses a timestamp more than `tolerance:` seconds (default 300) from now, which bounds replays. Headers may be a map or a list of pairs (`conn.req_headers`), names in any case. It returns the parsed event (`"type"`, `"created_at"`, `"data"`). Parse the body only after verifying: re-serialised JSON does not verify. Deliveries come from `51.161.117.92` with the user agent `BillionSend-Webhooks/1.0 (+https://billionsend.com/docs/concepts/webhooks)`; if the receiving endpoint sits behind a WAF or Cloudflare, allow them as the [webhooks documentation](https://billionsend.com/docs/concepts/webhooks) describes. A secret that is not a `whsec_` secret raises `ArgumentError`. `verify_webhook!/4` returns the event or raises.

## Resources

| Module | Covers |
| --- | --- |
| `BillionSend.Emails` (`.Attachments`) | send, batch, list, get, update, cancel, delete, share, unshare, insights, metrics; `Attachments.list`, `Attachments.get` |
| `BillionSend.Emails.Metrics` | links, countries, clients |
| `BillionSend.Emails.Receiving` (`.Attachments`) | received mail: list, get, delete, reply, forward; attachments and their extracted text |
| `BillionSend.Domains` (`.Claims`, `.UnsubscribePage.Logo`) | create, list, get, update, delete, verify; `Claims.create`, `Claims.get`, `Claims.verify`; `UnsubscribePage.Logo.upload`, `UnsubscribePage.Logo.delete` for the domain's own unsubscribe-page logo (its look, `support_url` and `powered_by` are set through `update` with `unsubscribe_page:`) |
| `BillionSend.Brand` (`.Logo`) | the team's brand defaults for the hosted unsubscribe pages: `get`, `update`; `Logo.upload`, `Logo.delete` |
| `BillionSend.ApiKeys` | create, list, update, delete |
| `BillionSend.Contacts` (`.Topics`, `.Segments`, `.Batch`, `.Imports`) | create, list, get, update, delete, preferences_link; `Segments.list`; `Batch.create`, `Batch.get`, `Batch.remove`; CSV uploads with `Imports.create`, `Imports.list`, `Imports.get` |
| `BillionSend.Audiences.Contacts` | contacts addressed through an audience |
| `BillionSend.ContactProperties`, `.Segments` (`.Contacts`), `.Topics` | contact data and grouping |
| `BillionSend.Broadcasts` | create, list, get, update, delete, send, duplicate, cancel, recipients, clicked_links |
| `BillionSend.Templates` | create, list, get, update, delete, publish, duplicate |
| `BillionSend.Webhooks` (`.Events`) | create, list, get, update, delete, rotate_signing_secret; `Events.list`, `Events.get`, `Events.replay`, `Events.Attempts.list` |
| `BillionSend.Automations` (`.Runs`) | create, list, get, update, remove, validate, duplicate, simulate, stop, metrics; `Runs.list`, `Runs.get`, `Runs.cancel` |
| `BillionSend.Events` | custom events: create, list, get, update, remove, send |
| `BillionSend.Logs`, `.OauthGrants` | request logs (list, get) and OAuth grants (list, revoke) |
| `BillionSend.Suppressions` (`.Batch`), `.Unsubscribes` | suppression list (`Batch.add`, `Batch.remove`) and opt-outs; an entry is for one address or, with `domain:` / `domains:`, for a whole domain: its `"email"` is `nil` then (`"kind"` says which, `"removable"` is `false` for a bounce or a complaint), and `list(client, kind: "all")` lists both |
| `BillionSend.Verifications` | availability, estimate, create, list, get |
| `BillionSend.Usage`, `.Deliverability` | account usage and sending health |
| `BillionSend.Inboxes` (`.Events`) | create, list, get, update, delete, send; `Events.stream`, `Events.stream_inbox` |
| `BillionSend.Inboxes.Agent` (`get`, `update`), `.Safety`, `.Labels`, `.Codes`, `.Quarantine`, `.Drafts` | inbox settings, labels, verification codes, held mail, drafts |
| `BillionSend.Inboxes.Threads` (`.Labels`, `.Emails`) | list, search, get, update, delete; thread labels; messages, reply and forward |
| `BillionSend.Agent` | signup, status, claim_email |

Three kinds of operation take a file: a CSV import and the two logo uploads. They send a `multipart/form-data` form, a file as `{filename, content}` (or `{filename, content, content_type}`), and a map or list field (`column_map`, `segments`, `topics`) as its JSON text. It queues the import; poll `Imports.get` for its `status` and `counts`:

```elixir
{:ok, upload} =
  BillionSend.Contacts.Imports.create(client, %{
    file: {"contacts.csv", File.read!("contacts.csv")},
    column_map: %{email: "Email", first_name: "First Name"},
    on_conflict: "skip"
  })

{:ok, upload} = BillionSend.Contacts.Imports.get(client, upload["id"])
```

A logo goes in the form's `file` field (PNG, JPEG or WebP, at most 2 MiB; the API judges the type from the bytes). `Brand.Logo.upload/3` sets the team's logo, `Domains.UnsubscribePage.Logo.upload/4` one domain's own; both answer `%{"object" => "logo", "logo_url" => url}`, and `delete` answers `%{"object" => "logo", "deleted" => true}`:

```elixir
{:ok, logo} =
  BillionSend.Brand.Logo.upload(client, %{file: {"logo.png", File.read!("logo.png"), "image/png"}})

{:ok, _} =
  BillionSend.Domains.UnsubscribePage.Logo.upload(client, domain_id, %{
    file: {"acme.png", File.read!("acme.png"), "image/png"}
  })

{:ok, brand} = BillionSend.Brand.update(client, %{accent_color: "#2B44FF", powered_by: false})
```

Each function is named after its operation's `operationId` in the API document: the groups make the module, the last segment the function, camelCase written in snake_case. `emails.receiving.attachments.list` is `BillionSend.Emails.Receiving.Attachments.list/3` and `agent.claimEmail` is `BillionSend.Agent.claim_email/2`. An `operationId` that is also the group of others needs nothing special in Elixir, since a module and a function of the same name live side by side: `emails.metrics` is `BillionSend.Emails.metrics/2` and `emails.metrics.links` is `BillionSend.Emails.Metrics.links/2`.

Arguments come in this order: the client, the path parameters (`BillionSend.Domains.get(client, domain_id)`; a `nil` or empty one raises `ArgumentError` instead of calling the whole collection), the request body as a map, or a keyword list, which is sent as an object (`BillionSend.Domains.create(client, %{name: "acme.dev"})`), then a keyword list of options: the query and header parameters (`BillionSend.Emails.list(client, limit: 50)`; a list parameter takes a list), `:extra_headers` and `:timeout`. A body the operation does not require may be left out (`BillionSend.Domains.verify(client, domain_id)`). An unknown option, or a missing required one, raises `ArgumentError` before anything is sent. Anything the functions do not cover goes through `BillionSend.Client.request(client, "GET", "/path", query: [...])`.

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

A 429 is retried for every method: the API refuses before it writes anything. Otherwise a request is retried when repeating it is safe: GET, PUT and DELETE (a file upload, a PUT included, is not: it is repeated only with an idempotency key), and any request carrying an idempotency key (every send does), on 5xx, when no answer came back (connection failure, timeout), and, for a keyed request, on 409 `concurrent_idempotent_requests` (a retry that caught the first attempt still running). The wait is the answer's `Retry-After` when there is one, otherwise exponential backoff with jitter (0.5 s, 1 s, 2 s… up to 8 s). An answer asking to wait more than 60 seconds, such as a used-up daily quota, is returned at once. `max_retries:` (default 2) bounds the retries of one call; `0` turns them off. The calling process sleeps between attempts.

## Configuration

| Option | Environment | Default |
| --- | --- | --- |
| `api_key:` | `BILLIONSEND_API_KEY` | none (only `Agent.signup` works without one; any other call returns `BillionSend.AuthenticationError`, `missing_api_key`) |
| `base_url:` | `BILLIONSEND_BASE_URL` | `https://api.billionsend.com` |
| `timeout:` | | `60_000` ms per attempt, a positive integer (an event stream waits at least 60 s for each read) |
| `max_retries:` | | `2` |
| `default_headers:` | | none |
| `transport:` | | the HTTP layer, `{module, state}` implementing `BillionSend.Transport` (`BillionSend.Transport.Httpc` by default: requests through `:httpc` in a profile of the SDK's own, one connection each; event streams on their own HTTP/1.1 connection that hands every event out as it arrives; both over `:ssl`, verifying the server against the system's CA store; `{BillionSend.Transport.Httpc, cacerts: [der, ...]}` verifies against your own CA instead, and `stream_read_timeout:` sets how long an event stream may stay silent) |

## Development

```bash
mix test          # offline: no network, no key
scripts/test.sh   # generate --check, format, compile, test and the coverage gates, in the pinned Elixir image
```

The SDK is built from a snapshot of the API's OpenAPI document, `openapi/api.openapi.json`. The snapshot is the contract: `scripts/generate.exs` writes `lib/billionsend/resources.ex` from it (module and function names from each `operationId`, idempotency keys where an operation declares the `Idempotency-Key` header, streams for cursor lists), and the tests hold the SDK to it:

- `test/operations_test.exs` runs every operation (186) through a contract mock and through the SDK's default transport on a real local socket, with only what the operation requires and with every parameter and body field it has; what the SDK sends is compared with what the document says it must send (path, query, headers, body), the answer is the document's own example or one built from its schema and must come back unchanged, and every kind of failure is followed. Every answer and every request is also validated against the document's schemas (`test/support/contract.ex`).
- `test/wire_test.exs` runs the default transport against real sockets, plain and TLS: headers, bodies, every kind of answer, event streams in every framing, certificate checks.
- `test/readme_test.exs` runs every code block of this README as written, against a local server that answers by the contract; a block that is added to the README and not to the test fails it.
- `test/client_test.exs`, `retries_test.exs`, `errors_test.exs`, `pagination_test.exs`, `streaming_test.exs`, `webhook_test.exs` and `new_operations_test.exs` cover the runtime: client options, retries and `Retry-After`, the error shapes, paging, the event stream and its decoder, webhook verification, uploads.

Coverage is a CI gate: `mix test --cover` fails below 95% of the lines of the hand-written code (`mix.exs`), `COVERAGE_SCOPE=generated mix test.coverage` below 95% of the lines of the generated code, and `scripts/branch_coverage.exs` below 95% of the branches of the hand-written code (Erlang's `cover` measures lines, not branches; the script says how it counts). To see the numbers:

```bash
mix test --cover --export-coverage all
mix test.coverage
COVERAGE_SCOPE=generated mix test.coverage
mix run --no-start scripts/branch_coverage.exs cover/all.coverdata --list
```

### Live tests

`test/e2e` runs the SDK against the real API. It is not part of `mix test` and CI does not run it:

```bash
BILLIONSEND_E2E_API_KEY=bs_... mix e2e
```

Every request is checked against the published OpenAPI document (`https://billionsend.com/docs/api.openapi.json`, downloaded at the start) before it is sent, and every answer after it is received, so a snapshot that has fallen behind the API fails here. The suite is written for a real account: it only reads what exists, creates objects named `sdk-e2e-elixir-<random>` and deletes them again (also when a test fails), sends at most 20 emails, only to `success@simulator.amazonses.com` and its plus-aliases and from the address `SDK E2E <sdk-e2e@mail.billionsend.dev>` (which the account must have a verified domain for), makes at most 150 requests, one a second, and stops on a second 429 in a row. It creates no domain, sends no broadcast, unsubscribes nobody and uses no inbox. The README examples that can run under these rules run there as written; the end of `test/e2e/live_test.exs` lists what cannot, and why.

When the API changes:

```bash
elixir scripts/sync_openapi.exs      # or: --from path/to/api.openapi.json
elixir scripts/generate.exs
mix test
```

Whatever fails is what the SDK has to follow. CI runs `scripts/generate.exs --check` so the generated code never drifts from the snapshot, and `scripts/sync_openapi.exs --check` (on every push and pull request, and once a day) so the snapshot never drifts from the published API: it fails when `https://billionsend.com/docs/api.openapi.json` differs from `openapi/api.openapi.json`. The offline tests never go online.

## Releasing

Publishing is manual; nothing is published on push.

1. On hex.pm, the owner of the `billionsend` package creates an API key with the `api:write` permission (Dashboard → Keys) and stores it in this repository as the `HEX_API_KEY` secret of the `hex` environment (Settings → Environments).
2. Set `@version` in `mix.exs`, turn the changelog's `Unreleased` heading into that version, commit, then tag and push: `git tag v0.2.0 && git push origin main v0.2.0`.
3. Actions → `release` → Run workflow, on the version tag. The workflow refuses a branch or a tag that differs from the version in `mix.exs`, runs every check, and publishes the package with `mix hex.publish package`.

The same release from a clean checkout of the tag is `HEX_API_KEY=… mix hex.publish package --yes`.

## License

MIT
