# FinanceKit PR 3489 review and validation

Review baseline: `4bcd8afc27bdfce53fe5cf3e0dc442fe8f19f6ff`.

This PR was simplified from a durable background upload inbox into a foreground
sync draft. The current branch deliberately avoids custom JOSE encryption,
device signatures, signed receipts, sequence/predecessor ordering, device
replacement fencing, scheduled inbox processing, and downstream completion
leases.

## Current shape

- Existing Sure API authentication protects all FinanceKit endpoints.
- `GET /api/v1/financekit/capabilities` advertises `foreground_sync`.
- `POST /api/v1/financekit/connections` enrolls a family-scoped connection with
  explicit consent.
- `PUT /api/v1/financekit/connections/{id}/account_mappings/{source_id}` creates
  or links one canonical account at a time.
- `POST /api/v1/financekit/connections/{id}/syncs` accepts typed JSON, validates
  the whole payload, imports synchronously, and returns applied counts.
- FinanceKit imports still disable heuristic matching, so one-card validation
  does not claim unrelated manual or CSV transactions.
- Family export no longer adds `financekit.json` in this draft.

## Remaining acceptance work

Run the focused FinanceKit tests, full Minitest suite, API documentation
generation, linting, and security checks on the pushed revision. Then validate
one synthetic native foreground sync against a disposable HTTPS instance.

Historical UUID reconciliation, mapping edits, and any future background/offline
delivery protocol remain separate follow-up decisions.
