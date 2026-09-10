# FinanceKit PR 3489 review and validation

Review baseline: `4bcd8afc27bdfce53fe5cf3e0dc442fe8f19f6ff`.

Use the tested revision for controlled Swift integration testing. The draft is
not a production contract pin and does not close all acceptance gates in #3485.

## Confirmed failures and corrections

- Both GitHub test jobs stopped at the pending FinanceKit migration. The
  migration now runs on PostgreSQL 16 and its generated schema is included.
- Pipelock mistakes the public interoperability key and synthetic signed
  messages for deployment credentials. The workflow now excludes only the
  documented Apple vector file and its generator. No production secret paths
  are excluded. The pinned scanner reports no findings for the PR diff.
- Production JWE decryption passed symbol allowlists to `json-jwt`, which compares
  the decoded string headers literally. Every otherwise valid upload failed.
  String allowlists now verify and decrypt the Apple-generated vector.
- Tombstone protection read `Entry#transfer_id`, but the database stores that
  identity on `Transaction`. It now checks the transaction's transfer. Deletion
  also uses a class-level transaction: the delegated `Entry#transaction` getter
  shadows the instance transaction method used by `with_lock`.
- Enrollment/health/replacement called a nonexistent JWK thumbprint method.
  They now use the library's RFC 7638 thumbprint generator.
- Mapping lost the payload's `action` field when extracting request data.
  The body is now kept distinct from routing parameters.
- Normal account reads failed because the FinanceKit adapter omitted the
  institution metadata interface. The adapter now includes the shared concern.
- API controllers now use the authenticated resource owner's scope, matching
  the API architecture checks rather than relying on the session bridge.
- Mapping checked only generic provider links, overlooking legacy Plaid and
  SimpleFIN links. It now uses the shared `linked?` predicate.
- Mapping discarded the initial booked-balance observation, allowing an older
  subsequent balance to overwrite it. New mappings retain that observation.
- Downstream completion acknowledged queue submission rather than completed
  rules, and could accept a sync begun before import. The persistent outbox now
  waits for newer account syncs and successful rule runs, with a retry lease.
  Sweep errors are isolated and contiguous inbox batches are drained in order.

## Validation

- Devcontainer: Ruby 3.4.9, Rails 8.1, PostgreSQL 16, Redis and remote Chromium.
  All database work used dedicated FinanceKit test databases.
- Standalone Apple vectors: 4 tests, 28 assertions, no failures/errors/skips.
- Direct invocation of production `Financekit::Crypto.verify` and `decrypt`
  successfully reproduces the Apple fixture payload after the correction.
- Ruby lint, ERB lint, Biome and Brakeman passed; API consistency checks passed.
- OpenAPI regenerated successfully: 409 documentation examples, no failures.
- Focused FinanceKit/API architecture suite: 53 tests, 235 assertions, no failures,
  errors or skips. Includes real database races and eventual balance/rule
  processing after the device stops making requests.
- Full Rails suite: 8,701 tests, 35,208 assertions, no failures or errors;
  33 skips remain in the repository suite.
- Full browser suite: 117 tests, 510 assertions, one trade-toast timeout while
  the full Rails suite ran concurrently. The failure screenshot shows the
  successful toast after the wait expired. Re-running both trade browser tests
  after the Rails suite finished passed (2 tests, 5 assertions). No unrelated
  trade code was changed; GitHub's separate system job remains the final check.
- The first full suite exposed an API architecture mismatch and an outdated
  family-export file list, both fixed. A direct-PG test also required `PGUSER`
  and `PGPASSWORD` in this devcontainer because it reads `config[:username]`
  while `database.yml` supplies `user`. This is a test environment setting.

## Remaining acceptance work

Confirm GitHub checks on the pushed revision. The focused tests cover concurrent
arrivals, revocation races, atomic
rollback, worker retry, missing sync jobs and pending/lost rule acknowledgments.

The issue also requires reviewable UUID reconciliation/cutover, mapping edits,
snapshot coverage reporting, overlapping destination-key rotation and abandoned
inbox retention. The original draft deliberately leaves these unresolved. Safe
rejection of unknown UUID continuity is useful, but does not complete those
requirements. See the protocol and hosting documents for the current limits.

Finally exercise the no-more-phone-requests scenario with normal Sure read APIs,
including eventual balances and rules, on a controlled deployment. Record its
revision and identify the merged commit before changing the Swift contract pin.
No merge, deployment, native pin change or production enablement is claimed here.
