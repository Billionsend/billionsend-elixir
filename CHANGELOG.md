# Changelog

## 0.3.1 (2026-11-26)

Snapshot synced to the published API (186 operations, none added or removed).

- Suppressions carry a `note`, why the entry is blocked: `BillionSend.Suppressions.create/3` and `BillionSend.Suppressions.Batch.add/3` take one (1 to 500 characters, stored on the rows the request creates; an entry that already exists keeps its own), and every entry answers it (`nil` on an entry SES wrote).
- `BillionSend.Domains.get/3` answers `sending_limits`, the broadcast limit the domain's registrable name is under (read-only, only on this call): `mode` (`warming`, `limited`, `unlimited`, `exempt` or `trusted`), `warmup_day`, `warmup_ends_on`, the running window (`window_started_at`, `cap`, `used`), the growth multiplier `g` with the warnings holding it (`g_reasons`), the deliveries it grows from (`t`, `b`), the recipients waiting for the next window (`parked`, `next_window_at`) and `hard_indicators` (`delivery`, `content_review`, `providers_in_backoff`). Only broadcasts are limited; API, SMTP and automation mail never are.
- A recipient's opt-out from a domain is permanent and covers transactional mail too unless the domain turned on `send_transactional_to_unsubscribed`; a broadcast body without the unsubscribe placeholder gets a default unsubscribe link when it is sent (server-side, as the published descriptions now say).

## 0.3.0 (2026-11-20)

Snapshot synced to the published API (`https://billionsend.com/docs/api.openapi.json`, now 186 operations).

- New: `BillionSend.Brand` (`get`, `update`) and `BillionSend.Brand.Logo` (`upload`, `delete`): the team's brand defaults for the hosted unsubscribe pages (`logo_url`, `accent_color`, `font`, `company_address`, `powered_by`, `show_topics`, and the read-only `powered_by_locked` and `branding_locked`). Writes need a key made by an owner or admin; a domain-scoped key is refused with `403` `restricted_api_key`.
- New: `BillionSend.Domains.UnsubscribePage.Logo.upload/4` and `.delete/3`: a domain's own logo on its unsubscribe pages.
- A logo upload is a `multipart/form-data` form with the image in `file`, as `{filename, content, content_type}` (PNG, JPEG or WebP, judged from the bytes, at most 2 MiB; `404` when the deployment has no logo storage, `422` for a refused file). It answers `%{"object" => "logo", "logo_url" => url}`; `delete` answers `%{"object" => "logo", "deleted" => true}`.
- A multipart upload is no longer repeated after a 5xx or a lost connection, whatever its method (the two logo uploads are `PUT`), unless it carries an idempotency key; a 429 is still retried, with the same form.
- `Domains.update/4`: `unsubscribe_page:` takes `support_url` (http or https, `nil` clears) and `powered_by` (`true`, `false`, or `nil` to follow the team's default). A domain's `unsubscribe_page` answers `support_url`, `powered_by`, the read-only `powered_by_effective` (whether recipients really see the line; always `true` on Free) and a `logo_url` that is `nil` when no logo storage is configured.
- Broadcasts: `Broadcasts.create/3` and `update/4` take `include_dormant` and `dormant_check` (the dormant-contact check, on by default), and a broadcast answers both as booleans.
- README: the logo uploads and the brand update, with the resource table.

## 0.2.2 (2026-11-19)

Snapshot synced to the published API (`https://billionsend.com/docs/api.openapi.json`, still 180 operations).

- Suppressions can block a whole domain. An entry has `kind` (`email` or `domain`), `domain` and `removable` (`false` for a permanent bounce or complaint entry), and its `email` is `nil` on a domain entry, so code that reads `entry["email"]` of a listed entry must allow `nil` (`list_all` included). `Suppressions.create/3` takes `domain:` in place of `email:`, `Suppressions.Batch.add/3` takes `domains:` (with or without `emails:`), and `Suppressions.list/2` takes `kind:` (`email`, the default, `domain` or `all`). A consumer mailbox provider such as gmail.com is refused as a domain.
- `Deliverability.get/2` answers `domains`: each sending domain's own standing (`domain_id`, `domain`, `status`, `tier`, `paused_by`, the counts and rates, `pause_margin`, `window_days`); a shared-domain row has no `domain_id` or `domain`.
- A paused sending domain refuses its sends with `403` `domain_sending_paused` (a `BillionSend.PermissionDeniedError`, like `sending_paused`, which is still the team's pause).
- The `deliverability.warning` and `deliverability.paused` webhook payloads carry `scope` (`team` or `domain`) and `domain` (`{id, name}`, `null` for the team).
- `custom_return_path` now defaults to `bounce` (it was `send`), is fixed when the domain is added, and `Domains.update/4` with it answers `422`.
- README: webhooks are delivered from `51.161.117.92` with a fixed user agent; allow them if the endpoint is behind a WAF.
- The live-test harness refuses a recipient at a domain the run suppressed.

## 0.2.1 (2026-11-19)

Snapshot synced to the published API (`https://billionsend.com/docs/api.openapi.json`, still 180 operations).

- Every operation a restricted key can be refused on now declares a `403` response (`restricted_api_key`, an `ErrorResponse`): 103 operations gained it and 74 existing ones name what a restricted key is refused. Only the public `POST /agent/signup` has none. The tests that check every declared error status cover them.
- `Emails.Receiving.list/2`: the `:inbox_id` option takes an inbox ID or the inbox's email address, as the `/inboxes/{inbox_id}` paths do (it was typed as a UUID only). An inbox that does not exist or belongs to another team answers 404; a malformed value answers 422.
- A path that ends with `/` now answers 404 `not_found` instead of 401 `missing_api_key`. The check that refuses an empty path parameter before sending is unchanged.

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
