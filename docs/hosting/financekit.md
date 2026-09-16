# Operating the FinanceKit foreground sync provider (draft)

FinanceKit is default-off and requires:

- `FINANCEKIT_ENABLED=true`.
- `FINANCEKIT_FAMILY_IDS`: comma-separated exact family UUID allowlist.
- An active enrolling administrator with preview features enabled.

No FinanceKit-specific server signing key, encryption key, scheduled inbox job,
or reverse-proxy exception is required in this foreground draft. Requests use
the same authenticated HTTPS API path as other Sure clients.

Deploy the migration and app code with the flag disabled, then enable only a
disposable test family. The native client should perform FinanceKit collection
while the user is active and call the foreground sync endpoint immediately.

## Testing

Use a disposable family and synthetic data on an HTTPS instance. Record the exact
backend revision (`git rev-parse HEAD`) in the native test notes.

1. Enable the global flag, allowlist only the test family, and enable preview
   features for its administrator.
2. Authenticate with the existing API and fetch `/api/v1/financekit/capabilities`.
3. Enroll with explicit consent for one source UUID.
4. Create or link one mapped Depository/CreditCard account with a confirmed
   subtype, currency, ledger timezone, and observed booked balance.
5. `POST /connections/{id}/syncs` with a bounded JSON `FinancekitPayload`.
6. Verify normal account and transaction APIs show the imported transaction,
   booked balance, pending state, and configured categorization.
7. Retry the same payload and confirm no duplicate ledger transaction is created.
8. Exercise invalid money, stale capture/balance, wrong mapping version, revoked
   connection, and source tombstone behavior.

The automated server counterpart is
`test/controllers/api/v1/financekit/connections_controller_test.rb`, supported by
the FinanceKit mapping/import model tests.

## Gates before native adoption

This is still a draft, not a shipping native contract. Before moving it out of
draft:

1. Run migrations with Ruby 3.4.9/Rails 8.1 and PostgreSQL.
2. Run the focused FinanceKit controller/model tests, the full Minitest suite,
   relevant system coverage, RuboCop, ERB lint, Biome, Brakeman, and OpenAPI
   generation.
3. Validate a synthetic native client against a disposable HTTPS instance using
   one mapped card/account and normal foreground authentication.
4. Decide whether background collection is actually needed. If it is, design it
   as a separate protocol after the foreground mapping/import path is proven.

Historical UUID reconciliation, mapping edits, and broader native UX remain
separate product decisions. The first backend contract should prove that
FinanceKit data maps cleanly into Sure without requiring background delivery,
custom encryption, or exactly-once stream semantics.
