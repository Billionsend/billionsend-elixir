# Changelog

## 0.1.0 (2026-11-17)

First release of the BillionSend Elixir SDK.

- Functions for every operation of the BillionSend API (139), in modules named after each operation's `operationId` (`BillionSend.Emails.Receiving.Attachments.list/3`): emails (with metrics, receiving, attachments and their extracted text), domains, API keys, contacts, audiences, contact properties, segments, topics, broadcasts, templates, webhooks, suppressions, unsubscribes, verifications, usage, deliverability, inboxes (agent and safety settings, labels, threads, quarantine, codes, drafts, event streams) and agent signup. Each returns `{:ok, answer}` or `{:error, error}`, with a `!` twin that raises.
- Answers decoded from JSON into maps with string keys.
- Errors as exception structs per status (`BillionSend.NotFoundError`, `BillionSend.RateLimitError`…) carrying `status_code`, `name`, `message` and `request_id` (the API's `x-request-id`); a call without an API key returns `BillionSend.AuthenticationError` (`missing_api_key`) before sending.
- Sending functions always send an `Idempotency-Key`: the caller's, or a UUID made up for the call and shared by its retries.
- Retries for requests safe to repeat (GET, PUT, DELETE and keyed requests) on 429, 5xx, failures without an answer and 409 `concurrent_idempotent_requests`, honouring `Retry-After` up to 60 seconds, else exponential backoff with jitter.
- Server-sent event streams as lazy enumerables of `BillionSend.InboxStreamEvent` and `BillionSend.StreamGapEvent`, resuming with `Last-Event-ID` after the server closes them or the connection drops, and raising `BillionSend.APIConnectionError` after `max_reconnects` reconnects in a row that fail to open (a connection that opens starts the count again, so a quiet inbox keeps its stream).
- `_all` functions returning lazy streams over every item of a cursor list.
- `BillionSend.verify_webhook/4` checks a webhook delivery's signature and timestamp and returns the parsed event.
- No dependencies: `:httpc`, `:ssl` and the built-in `JSON`.
