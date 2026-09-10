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
Each sweep drains up to 100 contiguous batches per connection. Downstream
completion waits for an account sync created after import and successful rule
runs, including their asynchronous enrichment work. Missing acknowledgments are
retried after a five-minute lease without another phone request. Rule/enrichment
execution is at least once; this does not promise exactly-once external calls.
A downstream failure leaves its outbox pending and does not stop other batches.

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

1. Run migrations with Ruby 3.4.9/Rails 8.1 and PostgreSQL. The schema is included.
   Run the full Minitest suite, relevant system coverage, RuboCop, ERB lint,
   Biome and Brakeman. See the [review record](../api/financekit-review.md)
   for validation results; controlled-instance validation remains necessary.
2. Regenerate OpenAPI with `RAILS_ENV=test bundle exec rake rswag:specs:swaggerize`
   and review the delta against the prepared schema/endpoint documentation.
3. Run the production-library Apple/Ruby vectors on the supported Ruby/OpenSSL
   runtime. Ruby 3.4.9 verifies signatures and decrypts the Apple vectors without
   skips. System Ruby/LibreSSL is not a supported interoperability test runtime.
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

## Controlled Swift integration testing

Use a disposable family and synthetic data on an HTTPS instance. Record the
exact backend revision (`git rev-parse HEAD`) in the Swift test configuration.
Apply the migration and run the Sidekiq scheduled worker before enrollment.
Provision fresh private RSA and P-256 keys through the instance's secret manager;
the published vector keys are public test material and must never configure a
real instance. Enable the global flag, allowlist only the test family, and enable
preview features for its administrator.

1. Authenticate with the existing API, fetch capabilities, and pin the returned
   server identity and public keys. Verify Apple/Ruby interoperability using
   `test/fixtures/files/financekit/apple_vectors.json` before uploading Wallet data.
2. Enroll one device with explicit consent for a source UUID. Create its mapping
   with a confirmed subtype, currency, ledger timezone and observed booked
   balance. Keep the returned connection generation and mapping version.
3. Sign and encrypt a bounded upload using the documented compact JOSE format.
   Send its immutable file as `application/jose` and verify the signed receipt's
   audience, batch UUID, generation, sequence and ciphertext digest.
4. Stop the client immediately after acceptance. Let the scheduled worker run;
   normal account/transaction reads must show the imported amount, booked balance
   and configured categorization. A successful receipt means canonical import;
   downstream completion is tracked separately on the batch.
5. Replay the same bytes and verify no duplicate transaction. Upload sequence 3
   before 2 and verify ordered processing after 2 arrives. Stop/restart workers
   with accepted rows and verify recovery without another device request.
6. Disconnect with an accepted upload outstanding; unapplied work must remain
   revoked and existing ledger data must remain. Repeat device replacement with
   confirmed stable UUIDs and verify old-generation uploads are rejected.

For this draft, mappings are immutable, snapshots are additive, and unknown UUID
continuity returns `identity_reconciliation_required`. Test those responses as
explicit limits; do not silently recreate historical transactions or retarget a
mapping. This test scope does not certify reinstall reconciliation, key-overlap
rotation, production retention policy, or physical iOS background execution.

The automated server counterpart is
`test/controllers/api/v1/financekit/connections_controller_test.rb`, supported by
the model concurrency, inbox, mapping and downstream tests. It exercises the
server without requiring a running Rails development server.
