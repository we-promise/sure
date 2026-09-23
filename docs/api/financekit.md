# FinanceKit background device publisher (protocol 2)

Related issue: [#3485](https://github.com/we-promise/sure/issues/3485).

FinanceKit is modeled as a device publisher inside Sure's provider architecture. The iOS client reads explicitly authorized Apple Wallet accounts, persists an encrypted local outbox, and uploads bounded batches whenever iOS grants foreground or background execution. Sure remains the financial system of record after a batch is accepted and applied.

The protocol deliberately separates two trust domains:

- Setup, account mapping, repair, conflict resolution, and disconnection use Sure's normal OAuth or `X-Api-Key` authentication.
- Batch upload uses a random, revocable credential restricted to one publisher URL. It cannot read financial data or call any other API.

TLS protects transport. The server stores only a SHA-256 digest of the publisher credential. Financial payloads are never written to request logs, receipts, or diagnostics.

## Eligibility and discovery

`GET /api/v1/financekit/capabilities` requires `read` access. It reports protocol version 2, `background_publisher` delivery, and server limits. Enrollment and management require `read_write`, an active family administrator, preview opt-in, `FINANCEKIT_ENABLED=true`, and an exact family allowlist match.

A disabled capability does not affect the caller's existing read-only Sure access.

## Enrollment, mapping, and activation

1. The client gets capabilities through the normal authenticated API.
2. The user selects Wallet accounts and explicitly acknowledges family visibility and remote processing. The client sends that immutable consent record to `POST /connections` with a stable enrollment UUID.
3. The client maps every selected FinanceKit account through `PUT /connections/{connection_id}/account_mappings/{source_id}`. It must explicitly create a canonical account or link a writable same-family account with the same currency and type.
4. `POST /connections/{connection_id}/activate` returns the upload URL, publisher and stream identifiers, generation, stable account-lineage bindings, limits, and the one-purpose publisher credential. The plaintext credential is returned only when it is issued.

Enrollment and mapping requests are idempotent for identical input. Conflicting reuse returns 409. A canonical account can have only one FinanceKit lineage writer and cannot be silently claimed from another provider.

`POST /credential` rotates a lost publisher credential without changing the stream. `POST /repair` revokes queued work and credentials, increments the generation, and starts a new stream at sequence 1. `DELETE /connections/{id}` revokes publishing and releases provider links while retaining already imported ledger history.

A replacement device enrolls with `replaces_connection_id`, maps to the prior lineage, then activates. Activation atomically revokes the old publisher. Lineage-owned transaction identities and tombstones survive, so replacement does not duplicate or resurrect financial activity.

## Ordered batch upload

`POST /publishers/{publisher_id}/batches` accepts `application/json` with the restricted bearer credential. The optional `Idempotency-Key` must equal `batch_id`; optional `X-Sure-Payload-SHA256` must match the exact request bytes.

Each immutable batch contains:

- connection, publisher, generation, and stream identifiers;
- a monotonically increasing sequence;
- the previous batch's SHA-256 payload digest, except on sequence 1;
- capture and chunk identifiers and indexes;
- capture mode and completion metadata;
- the exact selected account scope; and
- up to 500 typed account, balance, transaction, or tombstone events.

The server validates the complete payload before durably storing the exact bytes and returns 202 with a stable receipt. Retrying the same batch bytes returns the same receipt. Reusing its batch ID or stream position with different bytes returns 409. Up to 100 batches may wait per publisher, allowing later batches to arrive before a missing sequence. A capture must contain at most 100 chunks; larger histories must be split into multiple captures. Oversized captures are rejected with `413 capture_limit` before accepting any bytes into the inbox.

The inbox worker applies only the next contiguous batch whose predecessor digest matches. Canonical changes, the applied receipt, and the stream cursor commit in one database transaction. A crash before commit leaves the batch retryable; a crash after commit leaves an applied receipt. Permanent validation or stream failure fences the generation, revokes later queued batches and the credential, and requires explicit repair.

Payload bytes are removed seven days after application, permanent failure, or revocation. Digests, typed source identities, balance observations, tombstones, receipts, and audit-safe error codes remain.

## Event and financial semantics

The client receives a stable `lineage_id` and `mapping_version` for every selected FinanceKit source account. Every event repeats that binding. The server rejects stale or foreign mappings before import.

Amounts are unsigned exact decimal strings with explicit currency and `credit` or `debit` direction. JSON numbers, negative magnitudes, exponent notation, unknown currencies, and precision overflow are rejected. Sure normalizes signs once:

- transaction debit is positive expense and credit is negative income;
- asset balance credit is money held and debit is overdraft;
- credit-card balance debit is debt and credit is overpayment.

Balance observations are append-only source history. Only the newest booked observation materializes the canonical account balance. Reusing an observation identity with different money fails with `balance_observation_conflict` and requires repair; it never changes the retained observation or canonical balance. Available balance never replaces booked balance.

Transaction identity is the stable account lineage plus the FinanceKit source UUID. The provider adapter disables heuristic amount/date matching. Same-ID pending-to-booked transitions are supported; a changed source UUID remains a separate identity. Source-only `rejected` and `memo` records do not invent ledger activity.

Omission never deletes data, even for a complete snapshot. Only an explicit transaction tombstone may retract an unprotected FinanceKit-owned entry. User-edited, locked, reconciled, split, transferred, or otherwise protected records create a durable conflict instead. Open conflicts requiring review are listed at `GET /connections/{connection_id}/conflicts` and resolved explicitly with `PATCH /connections/{connection_id}/conflicts/{id}`. `keep_sure` closes the conflict while preserving the Sure ledger entry; `retry_after_repair` closes the conflict, fences the publisher into `repair_required`, revokes queued work and credentials, and requires the authenticated client to call `POST /repair` before uploads can resume.

## Health and recovery

`GET /connections/{id}` exposes separate timestamps for device contact, durable acceptance, canonical import, downstream scheduling, and capture time. This prevents a received batch from being presented as fully imported.

The client should handle responses as follows:

- 202: retain the receipt, then delete the matching local outbox batch.
- 401: stop uploads and use normal authentication to rotate the publisher credential.
- 403: publishing is revoked, ineligible, or requires repair; do not retry blindly.
- 409: stop the stream and fetch connection health. Repair when the server reports `repair_required`.
- 413: rebuild within the advertised byte and record limits.
- 429 or 503: retain the exact bytes and retry after `Retry-After` with bounded backoff.

OpenAPI schemas live in [schemas.json](financekit/schemas.json) and are loaded by `spec/swagger_helper.rb`.
