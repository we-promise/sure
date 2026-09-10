# Operating the FinanceKit device provider (draft)

FinanceKit is default-off and requires all of:

- `FINANCEKIT_ENABLED=true`.
- `FINANCEKIT_FAMILY_IDS`: comma-separated exact family UUID allowlist.
- `FINANCEKIT_SERVER_ID`: stable, installation-unique identity, pinned during
  authenticated foreground enrollment. Keep it stable across restarts and restores.
- `FINANCEKIT_ENCRYPTION_KEY`: PEM private RSA key, at least 3072 bits.
- `FINANCEKIT_RECEIPT_KEY`: separate PEM private P-256 EC signing key.
- Active enrolling administrator with preview features enabled.

Manage keys with the installation's secret-management system, not repository
files or public settings. Back up database, server identity and keys together.
Without the decryption key an accepted inbox cannot be recovered. Never log
keys or decrypted financial payloads. TLS-verified foreground discovery and key
pinning are required; do not enable an HTTP public enrollment endpoint.

Deploy the migration and app/worker code together, with the flag disabled. Run
`FinancekitInboxJob` through the configured Sidekiq scheduled queue every minute.
This schedule processes received records; it says nothing about how often iOS
collects Wallet changes. Observe last device contact, last accepted upload,
last completed canonical import and the separate downstream completion time.

Set reverse-proxy body limits to accommodate the 1 MiB outer JWS ceiling. The
application also bounds request reads and record counts. Configure Redis-backed
Rack::Attack on every web node; it limits FinanceKit upload attempts by IP, while
the database enforces per-connection inbox/new-batch budgets. Preserve Retry-After.

## Retention and lifecycle

Applied/revoked encrypted batch bodies are pruned after seven days by the inbox
sweep. Small receipts, sequence identities, source transactions and tombstones
remain until the enrollment/family is deleted, allowing replay detection after
payload pruning. Unapplied payloads remain recoverable while an operator repairs
an outage or sequence gap; outstanding data is bounded by 100 one-MiB uploads
per connection, with at most 20 active connections per family. Review blocked
connections regularly; a disconnected connection's unapplied bodies are removed
immediately. A retention limit for abandoned failed enrollments is an outstanding
operational decision before general rollout.

Database storage/backups contain normal financial ledger and source metadata;
apply the same storage encryption and access policy used for all Sure financial
data. `financekit.json` in family exports excludes encryption/signing keys and
retained encrypted uploads. Family financial reset and family/user deletion remove
enrollment records, source identities and receipts through their associations.

Disable intake/processing by switching the global flag off or removing a family
from the allowlist. Already imported data is preserved. Disconnect remains available
in the foreground while disabled. Revocation or explicit device replacement
fences unapplied uploads; received old-generation ciphertext cannot import later.

This draft has a single active destination key pair. For planned rotation, disable
intake, finish or explicitly revoke outstanding batches, preserve the old keys in
backup, rotate the keys, and require authenticated foreground rediscovery/explicit
pin replacement before resuming. Never silently replace pins on redirects. Seamless
multi-key overlap and a native pin-reconfirmation flow are not yet implemented.
An encryption-key compromise requires revoking enrollments, rotating keys and
foreground re-enrollment, not merely changing an environment variable.

Rollback should first disable the flag and stop FinanceKit scheduled work. Keep
the new tables when rolling app code back, so receipts and tombstones are preserved.
Do not reverse the migration on an installation containing accepted data without
an explicit data-export/retention decision.

## Gates before native adoption

This is an implementation draft, not a claim that #3485's acceptance checklist
has been completed. Before moving it out of draft:

1. Run migrations and generate `db/schema.rb` with Ruby 3.4.9/Rails 8.1 and
   PostgreSQL. Run the full Minitest suite, relevant system coverage, RuboCop,
   ERB lint, Biome and Brakeman. The author requested skipping local execution
   for this draft; CI and controlled-instance validation remain necessary.
2. Regenerate OpenAPI with `RAILS_ENV=test bundle exec rake rswag:specs:swaggerize`
   and review the delta against the prepared schema/endpoint documentation.
3. Run the production-library Apple/Ruby vectors. The local system Ruby uses
   LibreSSL with a broken GCM AAD binding; standalone signature/money checks
   passed, but its GCM cross-decryption check is explicitly skipped.
4. Exercise simultaneous uploads, disconnect/replacement races, failure between
   inbox commit and enqueue, rollback before acknowledgment, worker restart,
   downstream queue loss, user removal and family reset on a disposable instance.
   The draft contains regression tests, but these race/deployment gates are not
   claimed as completed.
5. Complete reviewable historical UUID reconciliation/cutover and mapping edits,
   snapshot coverage reporting, key-overlap rotation and abandoned-inbox retention.
   Current behavior stops safely on unproven UUID continuity and never infers
   deletion from a completed snapshot.
6. Run a synthetic client through foreground enrollment/mapping, one upload,
   immediate client stop, server recovery and normal Sure read APIs. Confirm
   canonical values and eventual balances/rules without another device request.

Only then identify the merged backend SHA for the Swift app to adopt deliberately.
Physical locked-device/extension/offline behavior is a subsequent native gate.
The Swift client's existing contract pin is unchanged by this server PR.
