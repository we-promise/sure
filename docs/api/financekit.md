# FinanceKit foreground sync provider (draft protocol 1)

Related issue: [#3485](https://github.com/we-promise/sure/issues/3485).

This draft intentionally uses a foreground "sync now" API. The native client
collects FinanceKit data while the user is active, then sends the typed payload
with the same authenticated Sure API mechanism used by other client requests.
It does not define a background device-upload protocol, encrypted inbox,
signed receipts, sequence/predecessor stream, or device replacement handshake.

All paths below start with `/api/v1/financekit`. Requests use Sure's existing
OAuth bearer token or `X-Api-Key` over HTTPS. Write operations require
`read_write`, an active family administrator, preview opt-in, and an explicit
family allowlist.

## Discovery and setup

`GET /capabilities` returns whether FinanceKit is available for the caller's
family, supported protocol versions, the foreground delivery mode, record
limits, amount precision, and supported transaction statuses. A server without
these routes can return 404. `available: false` means the feature is disabled
for this family; existing read-only API access remains usable.

Setup flow:

1. Fetch `/capabilities` from the authenticated Sure instance.
2. Ask the user for explicit FinanceKit upload consent.
3. `POST /connections` with `FinancekitEnrollment`. The request contains a
   stable client-generated `enrollment_id`, protocol version, and consent.
   Repeating the same enrollment is idempotent; changing it returns 409.
4. `PUT /connections/{id}/account_mappings/{source_id}` with
   `FinancekitMappingRequest`. Choose `create` or `link` explicitly. Creation
   requires subtype, currency, timezone, and an observed booked balance. Linking
   requires a writable same-family account with matching type/subtype/currency.
   Existing provider-backed accounts cannot be claimed.

`GET /connections/{id}` returns sanitized connection health and paginated
mappings. `DELETE /connections/{id}` revokes future foreground syncs and leaves
already-imported ledger data intact.

## Foreground sync

`POST /connections/{id}/syncs` accepts a JSON `FinancekitPayload` and imports it
inside the foreground request. The whole payload validates before canonical
ledger changes commit. A successful response returns `FinancekitSyncResult` with
an import id, `applied` status, captured/applied timestamps, and counts.

Limits:

- Request body: 1 MiB.
- Accounts per sync: 20.
- Combined transaction upserts and tombstones per sync: 500.

If a client loses the HTTP response, it may retry the same payload. Transaction
identity is keyed by the FinanceKit source UUID and mapped account, so the retry
does not duplicate ledger entries. The retry may create a second import summary,
but canonical financial data remains idempotent.

Sure records the last device contact, last imported timestamp, and last captured
timestamp on the connection. Older capture or balance observations cannot
overwrite newer state.

## Financial mapping

Amounts are unsigned exact base-10 strings with at most 15 integer digits and
four fraction digits. JSON numbers, exponent notation, negative magnitudes,
unknown currencies, precision overflow, and transaction/account currency
disagreement are rejected. Credit/debit carries direction; Sure maps debit to
positive expense and credit to negative income once.

For asset balances, credit is money held and debit is an overdraft. For credit
cards, debit is debt and credit is an overpayment. Booked and available balances
are retained separately. Only booked balance updates the canonical account
balance.

Timestamps require explicit ISO-8601 offsets. The canonical transaction date is
the posted timestamp for booked records, otherwise transacted time, converted
through the account's confirmed IANA timezone. Original timestamps, amount,
currency, direction, status, type, merchant, and description remain source
metadata.

Supported transaction states are `authorized`, `pending`, `booked`, `rejected`,
and `memo`. Authorized/pending records carry Sure's shared pending flag.
Rejected/memo records are retained as source-only records rather than invented
settled financial activity.

The provider import adapter disables heuristic matching for FinanceKit imports.
No automatic manual/CSV or amount/date pending claims are made. Different source
UUIDs remain different identities. Same-ID transitions respect user-edited,
import-locked, excluded, split, reconciled, and transferred records.

Explicit tombstones retract only unprotected provider-owned entries. Protected
entries remain for review. Identity and tombstone rows survive ledger deletion,
preventing replay resurrection.

## Error contract

- 400: malformed request, timestamp, or protocol.
- 401: missing or invalid authentication.
- 403: insufficient scope, preview/family gate, inactive member, account
  permission, revoked connection, or missing consent.
- 404: missing route, connection, or inaccessible resource.
- 409: enrollment, mapping, stale capture, stale balance, or source identity
  conflict.
- 413: request or record limit exceeded.
- 422: invalid typed records, consent, currency, precision, or subtype.
- 429: normal API rate limiting; honor `Retry-After` when present.
- 503: feature disabled or unconfigured; honor `Retry-After`.

OpenAPI schemas live in [schemas.json](financekit/schemas.json) and are loaded
by `spec/swagger_helper.rb`. Request documentation is generated from
`spec/requests/api/v1/financekit_spec.rb`.
