# Enable Banking direct legacy admission

Status: implementation and behavioral tests are authored, not executed acceptance.
Enable Banking's native readiness remains false. This work does not run a data
copy, switch a connection, renew consent or remove legacy records.

## Acquisition and financial publication

[`LegacyAccess`](../../app/models/enable_banking_item/legacy_access.rb) specializes
the shared legacy admission boundary for Enable Banking. A direct importer,
processor or coordinator must retain the original item's migration permit. A
quiescing, native, retired or otherwise incompatible owner refuses that work.
Scheduled deletion also refuses new ingestion and publication.

The transport fingerprint includes the application identity and certificate,
authorization/session identity and expiry, institution consent configuration,
PSU settings, history floor and family timezone. An already constructed importer
or processor cannot adopt replacement consent. The real injected API client must
also match the admitted application identity and private key. HTTP runs outside
database transactions while the item permit prevents migration from overtaking it.

Source fingerprints retain the original local/API identifiers, identification
hashes, cached payloads, credit interpretation, financial account and link context.
The importer verifies these around acquisition and saves responses through short
locked snapshot commands. It returns the resulting source and transport contexts
to its coordinator: its own accepted expiry or snapshot updates may advance that
operation, while an intervening relink, cache edit or consent change cannot.

The account, transaction-batch and entry processors carry those original contexts
through publication. The shared command rechecks the financial account, source,
item, links and selected resource authority under row locks. Balance publication
constructs its transaction processor from the resulting locked context, so the
same operation can publish a legitimate account-currency update. Later processing
must still reject a different operation's changed context. Failed transaction or
merchant persistence rolls back its publication savepoint before reporting failure.

The coordinator admits the exact original Sync, updates progress through scoped
locked writes, propagates ownership refusals and rejects failed account results.
This prevents failed financial processing from becoming a successful import merely
because cached API data was saved.

## Read bounds and verification

Inventory loops preflight up to 2,000 source headers and a combined 16 MiB stored
cache budget before materialization. Their hydration query selects the exact
observed PostgreSQL row tuples; a changed tuple refuses capture. Decoded source
payloads also have a size check. Individual inherited reload/lock paths still use
defensive size checks rather than an atomic pre-hydration bound, and repeated
full-cache fingerprints need realistic performance acceptance. These limits are
not a claim of a process-wide memory cap.

The [direct admission regressions](../../test/models/enable_banking_item/admission_test.rb)
use committed fixtures and actual migration permits. They cover successful direct
import/publication, a coordinator-owned currency change, refusal of stale owners
and Syncs, relink/cache/consent changes during acquisition, stale constructors,
SQL rollback/retry, row contention, transaction-free HTTP and scheduled deletion.
Existing legacy tests retain a narrow fixture compatibility helper; they do not
replace these real-commit boundary cases. Ruby and Bundler are unavailable here,
so no behavioral or lint acceptance is claimed.

## Work still required before native cutover

Follow-on implementations now cover [legacy consent lifecycle admission](enable-banking-consent-lifecycle.md),
[native inventory membership publication](enable-banking-authorization-inventory.md)
and [retained history verification](enable-banking-cutover-history.md). They are
authored work with unrun tests, not completed migration acceptance. In particular,
signed legacy account selection/setup/linking, native grant status and
renewal/revocation management, uncertain upstream revocation reconciliation,
authorization-aware retirement, large-cache performance and end-to-end
pending/history/migration acceptance remain gates. See the
[migration matrix](bank-data-provider-migration-matrix.md) and
[implementation status](provider-implementation-status.md).
