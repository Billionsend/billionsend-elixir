# Changelog

## 0.2.0 (2026-11-19)

The SDK follows the published API again: the OpenAPI snapshot it is built from had fallen behind, so `BillionSend.Usage.get/2` and other functions still described the old shapes.

- Snapshot synced to `https://billionsend.com/docs/api.openapi.json`: 180 operations (was 139).
- New functions: `BillionSend.Automations` (list, get, create, update, remove, validate, duplicate, simulate, stop, metrics) and `.Runs` (list, get, cancel); `BillionSend.Events` (list, get, create, update, remove, send); `BillionSend.Contacts.Imports` (list, get, create) and `Contacts.Segments.list`; `BillionSend.Domains.Claims` (create, get, verify); `Emails.share`, `Emails.unshare` and `BillionSend.Emails.Attachments` (list, get); `Broadcasts.recipients` and `Broadcasts.clicked_links`; `BillionSend.Logs` (list, get); `BillionSend.OauthGrants` (list, revoke); `BillionSend.Webhooks.Events` (list, get, replay) with `.Attempts.list`, and `Webhooks.rotate_signing_secret`; `ApiKeys.update`; `Inboxes.Agent.update`.
- `Contacts.Imports.create/3` uploads a CSV as `multipart/form-data`: a file is `{filename, content}` (or `{filename, content, content_type}`), a map or list field is sent as its JSON text (`BillionSend.Multipart`, and `:multipart` in `BillionSend.Client.request/4`).
- Removed: `Unsubscribes.delete` (the API no longer has it; an opt-out is the recipient's to undo) and `Webhooks.rotate`, replaced by `Webhooks.rotate_signing_secret`.
- Answers and requests changed with the API's: `Usage.get` now answers `emails.daily` / `emails.monthly`, `contacts`, `domains` and the other limits in place of the old `limits` block, and the contact, domain, broadcast, webhook, template and inbox shapes follow the new schemas.
- `scripts/sync_openapi.exs --check` fails when the snapshot differs from the published document; CI runs it on every push and pull request and once a day. The tests stay offline.
- Fixed: a POST, PUT or PATCH without a body (38 operations, among them `Domains.verify`, `Emails.cancel`, `Templates.publish`, `Broadcasts.send` and every update called with no fields) failed with `APIConnectionError` `:invalid_request` through the default transport; it now goes out with an empty body.
- Fixed: a request whose connection's `:httpc` handler process died without answering (killed, crashed, taken down with its supervisor) waited out the whole timeout, 60 seconds by default, for an answer that could not come: `:httpc`'s synchronous call never hears of it. The default transport now sends asynchronously and watches the handler, and fails at once with `BillionSend.APIConnectionError` (`:connection_handler_exited`); a request that is simply slow, or whose peer has gone silent, still ends with `APITimeoutError` at its timeout. A request without an idempotency key is not repeated.
- Fixed: an event stream that was dropped right after the position it was sent (`id:` with no event) resumed from nowhere and lost the events in between; it resumes from that position.
- A key with whitespace around it (a trailing newline from a file) is trimmed; a header value that is not printable ASCII (an idempotency key with non-ASCII text, a line break) raises `ArgumentError` before sending instead of surfacing as a retried connection error; a `nil` or empty path parameter raises `ArgumentError` instead of calling the whole collection (`Domains.get(client, "")` returned the list); a `timeout:` that is not a positive integer raises instead of being ignored; a keyword list as a request body is sent as an object; `verify_webhook` with a payload that is not the raw body raises an `ArgumentError` that says so.
- `BillionSend.Transport.Httpc` takes `cacerts:` (verify against your own CA) and `stream_read_timeout:` in its state.
- No more compile warnings on Elixir 1.20.
- A 429 is retried for every method, after its `Retry-After`: the API refuses before it writes anything, so a POST or PATCH without a key is safe to repeat (it was returned at once).
- A path parameter that is `.` or `..` raises `ArgumentError` (it would be folded into another route); an empty list in a query is not sent; `verify_webhook` accepts a secret with whitespace around it, header values with whitespace and signatures separated by any whitespace.
- README: the agent example keeps only `inbox.email.received` (an inbox's own stream also carries `inbox.deleted` and `inbox.expired` whatever `types:` says), and the list of sending functions includes `Events.send`.

## 0.1.0 (2026-11-17)

First release of the BillionSend Elixir SDK.

- Functions for every operation of the BillionSend API (139), in modules named after each operation's `operationId` (`BillionSend.Emails.Receiving.Attachments.list/3`): emails (with metrics, receiving, attachments and their extracted text), domains, API keys, contacts, audiences, contact properties, segments, topics, broadcasts, templates, webhooks, suppressions, unsubscribes, verifications, usage, deliverability, inboxes (agent and safety settings, labels, threads, quarantine, codes, drafts, event streams) and agent signup. Each returns `{:ok, answer}` or `{:error, error}`, with a `!` twin that raises.
- Answers decoded from JSON into maps with string keys.
- Errors as exception structs per status (`BillionSend.NotFoundError`, `BillionSend.RateLimitError`…) carrying `status_code`, `name`, `message` and `request_id` (the API's `x-request-id`); a call without an API key returns `BillionSend.AuthenticationError` (`missing_api_key`) before sending.
- Sending functions always send an `Idempotency-Key`: the caller's, or a UUID made up for the call and shared by its retries.
- Retries for requests safe to repeat (GET, PUT, DELETE and keyed requests) on 429, 5xx, failures without an answer and 409 `concurrent_idempotent_requests`, honouring `Retry-After` up to 60 seconds, else exponential backoff with jitter.
- Server-sent event streams as lazy enumerables of `BillionSend.InboxStreamEvent` and `BillionSend.StreamGapEvent`, resuming with `Last-Event-ID` after the server closes them or the connection drops, waiting what a 429 or 5xx's `Retry-After` asks before the next reconnect (over 60 seconds raises that error at once), and after `max_reconnects` reconnects in a row that fail to open raising the API's error for the last one, or `BillionSend.APIConnectionError` when it got no answer (a connection that opens starts the count again, so a quiet inbox keeps its stream).
- `_all` functions returning lazy streams over every item of a cursor list.
- `BillionSend.verify_webhook/4` checks a webhook delivery's signature and timestamp and returns the parsed event.
- No dependencies: `:httpc`, `:ssl` and the built-in `JSON`.
