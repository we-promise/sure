# FinanceKit device provider (draft protocol 1)

Related issue: [#3485](https://github.com/we-promise/sure/issues/3485).
This implementation is based on Sure `main` at
`307d1b61d1d1617c060e3a78933615ea71070c8e`, rather than the issue's analysis
baseline `5594f8bc94c8e659838cac70d826bbcaeaa3bae2`. Main already derives the
provider-import pending SQL and pending flag clearing from
`Transaction::PENDING_PROVIDERS`; FinanceKit extends that shared list.

**Draft: do not pin this contract in a shipping native client yet.** The Rails,
request, migration, concurrency and recovery suites must run on the supported
runtime; a controlled deployment and native interoperability review remain
release gates. The PR author explicitly requested a draft without local tests.
See [operations and release gates](../hosting/financekit.md).

## Boundary and discovery

Sure owns the ledger, categorization, transfer matching and balance calculation.
The phone owns FinanceKit authorization, history tokens, collection and immutable
upload files. The server never calls a phone or claims an hourly Wallet fetch.

All paths below start with `/api/v1/financekit`. Foreground requests use Sure's
existing OAuth bearer or `X-Api-Key` authentication over HTTPS. Administration
requires `read_write`, an active family administrator, preview opt-in and the
operator's explicit family allowlist. Read operations require `read` (or
`read_write`). Connections are owned by their enrolling user within the family;
account links additionally require `Account.writable_by(user)`.

`GET /capabilities` returns the protocol/envelope versions, record/byte limits,
financial precision, supported transaction statuses and pinned server keys.
An authenticated enabled user sees `available: false` when the operator disables
FinanceKit. A server without these routes can return 404. Either result leaves
all existing read-only features usable. **Never fall back to the generic
transaction-write API.** Feature-gating 403 is not invalid credentials.

OpenAPI includes the typed schemas from [schemas.json](financekit/schemas.json),
also loaded by `spec/swagger_helper.rb`. Request documentation is in
`spec/requests/api/v1/financekit_spec.rb`. The current OpenAPI additions were
assembled from the same definitions; run rswag regeneration before merge.

## Foreground setup

1. Generate a P-256 signing key on the device. Keep the private key on that
   device; do not share the app's OAuth refresh token with the background extension.
2. Fetch capabilities from the user's authenticated, TLS-verified Sure instance.
   Pin the server identity, RSA encryption key and separate P-256 receipt key.
3. Obtain explicit upload consent, separately from Wallet permission. Consent
   version 1 names the selected source account UUIDs and acknowledges configured
   Sure enrichment destinations.
4. `POST /connections` with `FinancekitEnrollment`. Persist a random enrollment
   UUID before the request. Repeating it with the same typed content returns the
   same connection. Reusing it with different content is 409.
5. `PUT /connections/{id}/account_mappings/{source_id}` with
   `FinancekitMappingRequest`. The first `expected_version` is zero. Choose `create`
   or `link` explicitly. Confirm Depository/CreditCard and a supported subtype,
   exact currency and IANA ledger timezone. Creation additionally requires an
   observed booked balance; no zero/currency defaults are inferred. Linking
   requires a writable same-family account with matching type/subtype/currency.
   Any existing provider prevents the link. A reciprocal AccountProvider guard
   prevents another provider from attaching after FinanceKit has claimed it.

Source mappings are immutable in this draft. Exact retries accept version zero
or the resulting version one. A changed mapping returns 409 rather than
retargeting already accepted records. `GET /connections/{id}` returns sanitized
health plus mappings ordered by persisted ID, with `page`, `per_page` (1–100,
default 25), and total counts. An empty page is a successful response.

## Immutable upload format

The HTTP body for `POST /connections/{id}/batches` is a **compact JWS**, with
`Content-Type: application/jose`. No Authorization, API key, session cookie,
refresh token or other general financial credential belongs on this request.
The extension can persist these bytes to a file for a background URLSession.

Cryptography uses existing `jwt` and `json-jwt` libraries and standard JOSE:

- RFC 7515 JWS, `alg: ES256`, `typ: sure-financekit+jwt`. Signature is the 64-byte
  `r || s` representation, not an ASN.1 DER signature. Header contains only `alg`
  and `typ`; untrusted key URLs and algorithm negotiation are rejected.
- JWS payload is UTF-8 JSON matching `FinancekitEnvelopeClaims`. It binds the
  configured server identity in `aud`, connection UUID, protocol 1, publishing/
  selection generation, batch UUID, positive stream sequence, predecessor digest,
  ciphertext and its exact SHA-256 digest. Sequence integers are at most 2^53−1.
- The ciphertext field is RFC 7516 compact JWE with exactly
  `{"alg":"RSA-OAEP","enc":"A256GCM"}` as the protected header. RSA is at least
  3072 bits. `RSA-OAEP` here means SHA-1/MGF1-SHA-1 with an empty label, as defined
  for that JOSE algorithm; **it does not mean RSA-OAEP-256**. AES uses a fresh
  256-bit content key, a fresh 96-bit nonce and a 128-bit authentication tag.
  There is no compression. The protected-header base64url text is AES-GCM AAD.
- JWE plaintext is UTF-8 JSON matching `FinancekitPayload`. `digest` is lowercase
  hex SHA-256 of the exact UTF-8 compact JWE bytes. The authenticated JWE commits
  to the exact plaintext. Re-encrypting the same data produces a different batch
  digest; retry the original file byte-for-byte.
- All JOSE parts use unpadded base64url. JSON key order is not prescribed: signing
  and digest verification use the serialized bytes, never a reserialized object.
- Sequence starts at one with a null predecessor. Each subsequent batch binds
  the preceding batch's ciphertext digest. Serialize capture batches locally;
  network arrival may be out of order. Apple history tokens never leave the phone.
- There is intentionally no short JWT expiry: iOS can delay a queued transfer.
  Authorization is instead checked against the active user, selected accounts,
  pinned device key and current revocable generation on intake and processing.

A redirect can disclose connection metadata and encrypted bytes, but not the
financial plaintext or a reusable general API credential. Only the pinned server
key decrypts the payload. Another destination cannot produce a valid receipt.
Foreground key discovery must use the user's authenticated HTTPS destination;
never discover or replace pins from an upload redirect or upload error response.

### Receipt verification

An accepted request returns HTTP 202 and `FinancekitReceipt`, a separate ES256
JWS with `typ: sure-financekit-receipt+jwt`. Verify the pinned receipt public key,
`iss`, connection `aud`, protocol, generation, batch UUID, sequence and exact
ciphertext digest before acknowledging any local upload file. The signature
protects status, counts, acceptance/import timestamps and sanitized error code.
A receipt for another batch is not an acknowledgment. A previously valid accepted
receipt does not prove the current state; status observations must not regress
an already observed applied receipt. `issued_at` is signed but is not a freshness
challenge. Foreground code can fetch the latest signed receipt with:

`GET /connections/{id}/batches/{batch_id}?generation=1`

The background extension does not need to poll this operation. Completion,
retries, recovery and downstream scheduling happen on the server.

## Inbox and completion semantics

A whole bounded batch validates before its encrypted envelope is committed.
Limits are 1 MiB **outer JWS bytes**, 20 accounts, 500 combined transaction upserts
and tombstones, 100 queued batches per connection and 120 new batches/hour per
connection. IP throttling also applies before expensive cryptography.

Same identity/digest returns its existing receipt, including after encrypted
payload pruning. A reused identity or sequence with different content is 409.
Out-of-order arrivals wait as `accepted` until their predecessor arrives. A gap
is never skipped. The scheduled worker discovers committed inbox rows every
minute, independent of enqueue success or another client request.

The worker locks the connection and applies the next contiguous batch. Source
identities, canonical changes, statistics, the applied receipt and sequence
advance share one database transaction. Process death rolls it all back; the
next sweep rediscovers the accepted row. `processing` is a transactional internal
state, normally not visible to another request. Older capture or balance
observations cannot overwrite newer state. Transient failures retry at bounded
exponential intervals (2, 4, 8, 16 minutes; the fifth failure is terminal).
Invalid streams become `failed` with a stable error code and block successors.
Repair uses an explicit foreground generation replacement/resnapshot; it never
changes an immutable batch or quietly skips it.

`applied` means canonical source/entry/balance intake committed. It is distinct
from the subsequent standard account balance materialization, transfer matching,
and configured rules/enrichment. The batch's durable downstream outbox keeps
requesting account sync until completion is observable, then schedules normal
Sure rules. End-to-end exactly-once external enrichment is not promised by the
existing rule queue. Queue-loss/restart and rule scheduling need a controlled
failure-injection review before production rollout.

A snapshot is additive. `history.start_at/end_at` declare its observation window,
`snapshot_id` groups segments, and `complete` labels the final segment. Completion
does not authorize deletion or prove earlier segments arrived. A narrower
history window, missing page, disappearing account, revoked permission, or
disconnect never removes ledger history. Only explicit source tombstones request
retraction.

## Financial mapping

Amounts are unsigned, exact base-10 strings, at most 15 integer and four fraction
digits, reflecting Sure's existing numeric(19,4) ledger. JSON numbers, exponent
notation, negative magnitudes, unknown currencies, precision overflow and
transaction/account currency disagreement are rejected. Credit/debit carries
direction; Sure maps debit to positive expense and credit to negative income
once. Refunds and card payments are credits. No device FX conversion is allowed.

For asset balances, credit is money held and debit is an overdraft. For credit
cards, debit is debt and credit is an overpayment. Booked and available balance
observations are retained separately. Only booked balance updates the canonical
account balance. Available credit is never a replacement booked balance.

Timestamps require explicit ISO-8601 offsets. The canonical transaction date is
the posted timestamp (required for booked records), otherwise transacted time,
converted through the account's confirmed IANA timezone. Original timestamps,
amount/currency/direction, status/type, merchant and description remain source
metadata. Supported states are authorized, pending, booked, rejected and memo;
authorized/pending carry the shared pending flag. Rejected/memo are retained as
source-only records rather than invented settled financial activity.

The provider import adapter's identity-only mode disables automatic manual/CSV
and amount/date pending claims. Different UUIDs remain different identities.
Same-ID transitions respect excluded/import-locked/user-edited records and retain
server categorization. An explicit tombstone retracts only an unprotected,
provider-owned entry. Edited, locked, split, reconciled or transferred records
remain for review. Identity/tombstone rows survive ledger deletion, preventing
replay resurrection. Retractions have sanitized audit records and schedule normal
account recalculation.

## Replacement, selection and revocation

`POST /connections/{id}/device_replacement` uses an optimistic
`expected_generation`, new device public key and renewed explicit consent. It
atomically revokes queued old-generation work, preserves mapped source identities
and existing ledger data, resets sequence/predecessor and increments generation.
Use the same operation/key to change the selected account scope. Removed source
mappings and their history remain; uploads outside the new consent are rejected.

Continuity must be explicitly confirmed as `same_source_and_transaction_ids`.
If a reinstall or replacement changes FinanceKit UUIDs, the server returns
`identity_reconciliation_required` (409). **Historical UUID reconciliation and
mapping retargeting are not implemented in this draft.** Do not assert continuity
merely to bypass the error, recreate transactions with generic writes, or match
purchases by amount/date. A reviewable reconciliation/cutover workflow is a
remaining native-readiness gate.

`DELETE /connections/{id}` revokes ingestion and cancels unapplied work. Existing
ledger entries, mappings, receipts and audit history remain. The endpoint remains
usable with the operator flag off. Deleting a user or resetting/deleting family
financial data removes the enrollment and its source/inbox rows; no device
credential can outlive its enrollment. Ordinary family exports include a
`financekit.json` file with source identity, consent, balances and receipts;
private keys and encrypted upload bodies are excluded.

## Error and retry contract

| HTTP | Meaning | Client action |
| --- | --- | --- |
| 400 | Malformed JWS/JWE, digest, timestamp parameter, content type or protocol | Correct locally; do not retry unchanged |
| 401 | Missing/invalid foreground credentials or device signature | Foreground repair; no refresh-token sharing |
| 403 | Scope, preview, consent, inactive member, account permission, revoked connection | Explain authorization state; require explicit action |
| 404 | Missing route/connection/receipt or inaccessible resource | Discover capability or verify foreground configuration |
| 409 | Enrollment, mapping, identity, generation, predecessor or sequence conflict | Read connection/receipt; explicitly repair the stream |
| 413 | Byte or record limit exceeded | Split before assigning fresh batch identities; never mutate accepted bytes |
| 422 | Typed record, consent, currency, precision or subtype validation | Correct data; whole batch was not accepted |
| 429 | IP, connection or inbox limit | Honor Retry-After (seconds); retry identical bytes with backoff |
| 503 / other 5xx | Disabled/unconfigured service or server failure | Honor Retry-After when present; retry identical bytes with bounded backoff |

After an ambiguous network failure, retry the same file: the inbox receipt handles
lost acknowledgments. Never infer a successful import from HTTP 202 alone.

## Interoperability artifacts

`test/fixtures/files/financekit/` includes success, empty, malformed and conflict
samples, plus Apple-produced JOSE vectors. The RSA private key in `apple_vectors.json`
is **public test material**, generated solely for this fixture; it must never be
used in a deployment. P-256 public keys, signed upload/receipt, exact plaintext,
and ciphertext digest let Swift/Ruby implementations compare actual bytes.

`test/support/financekit/generate_vectors.swift` uses Apple Security/CryptoKit.
`test/support/financekit/verify_apple_vectors.rb` verifies the wire artifacts with
standard Ruby/OpenSSL; the Rails CryptoTest also exercises production JOSE libraries.
Generating new vectors is intentional: randomness changes all ciphertext/signature
values. Commit the generator and corresponding fixture together.
