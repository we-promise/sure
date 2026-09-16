# Akahu direct legacy admission

Status: implementation and behavioral coverage authored; runtime tests remain
unrun because Ruby/Bundler are unavailable. Akahu native readiness is still false.
This adds direct ingestion/publication and legacy browser lifecycle guards needed
for migration. [Native connection management](akahu-native-lifecycle.md) is also
authored; executable acceptance remains a gate.

## Ownership and publication

[`AkahuItem::LegacyAccess`](../../app/models/akahu_item/legacy_access.rb) declares
its source fields and both token inputs on the shared
[`Provider::AccountData::LegacyAccess`](../../app/models/provider/account_data/legacy_access.rb).
Direct importer, item/account snapshots, financial processors and Syncer join the
existing migration permit. Quiesced/native/retired ownership refuses these writers.
The provider client is built after admission; a supplied client must match the
original admitted credentials. HTTP runs outside row transactions while the permit
prevents migration from draining the item midway through acquisition.

Requests pin both credentials, configuration, original source/cache, account link
and financial context. Short publication transactions lock and recheck the Account,
item, source, mapped external account and link. They pin fresh associations before
yielding financial work and roll back a failed unit. Transaction and balance writes
respect current source policies; a secondary feed may retain observations without
acquiring posting authority. Inactive retained selections do not silently promote
a legacy source. Ownership denials propagate through importer/processor rescues.
Support diagnostics retain stage and owner identifiers without raw response or
credential values.

The Syncer validates its original persisted Sync before progress writes, then
keeps one permit through import, financial processing and account scheduling.
Status, setup flags and merged statistics recheck the original credential context
and current Sync in short locked transactions. Cancellation or ownership changes
propagate as admission errors rather than being reported as ordinary sync failure.

## Complete pending inventory

The old pending reader returned only the first response page; posted/discovery
readers could also mistake a malformed payload for an empty result. All legacy
collection readers now share complete bounded pagination and reject malformed
response shapes, failed responses, repeated cursors and limits. A successful empty
response explicitly persists an empty cache. A failed pending refresh preserves
prior pending rows, returns failure and cannot issue cleanup authority.

[`AkahuAccount::PendingCleanup`](../../app/models/akahu_account/pending_cleanup.rb)
uses an in-memory receipt issued with the source cache commit. It binds the complete
pending response to the original uninterrupted permit/database session, source and
transport context, stored cache version, and bounded original pending Entry and
Transaction row versions. The permit retains the exact latest issued receipt
object per source, so a cloned or superseded receipt cannot authorize deletion.
The sync coordinator passes it directly to processing;
it is not serialized into jobs or reconstructed from cached absence.

Cleanup rechecks that receipt under financial/source locks. It only considers the
captured candidate IDs, preserves currently observed IDs and idless collision
suffixes, and skips user-protected, reconciled, split, transfer and evidence-owned
entries. Candidate mutation refuses the cleanup transaction; later-created entries
are outside its authority. Cache-only processing and failed financial processing
never prune. Missing, unsupported or nonfinite posted amounts fail the row rather
than becoming zero; that failure also prevents cleanup. Receipt reuse after permit
release or cache replacement refuses.

A balance publication that changes account currency invalidates the original
financial-context proof. Pending cleanup then conservatively refuses; it does not
reinterpret old pending money in the new currency. That case still requires a
reviewed currency-transition policy before full parity acceptance.

## Browser lifecycle

[`AkahuItem::Lifecycle`](../../app/models/akahu_item/lifecycle.rb) now owns creation,
credential/settings changes, discovery, account linking and disconnect. Commands
reload the active administrator and family; existing-account mutations also
require current owner/full-control permission. Credential replacement drains
legacy work through an exclusive permit, retaining blank-token update semantics.
Discovery captures transport and source context before HTTP, validates a complete
bounded inventory and publishes snapshots in one short transaction. Locks cover
the original financial accounts, item, sources and links before revalidation.

All three account picker forms carry an actor/action/target-bound
[`Selection`](../../app/models/akahu_item/selection.rb). Its signed fingerprint
retains both credentials, timezone, migration ownership and exact source/link
inventory without exposing credential values. Changed source caches, links or
ownership require reopening the form. Account creation and linking remain atomic;
Akahu liability signs, subtype suggestions and investment cash behavior are retained.

Disconnect checks the complete link inventory and each account's permission before
detaching holdings and links in one transaction. Retained shared links or source
policies require a separate migration disposition. Deletion dispatch happens after
commit and permit release; direct `destroy_later` refuses still-linked or nonlegacy
items. `unlink_all!` uses the same command with deletion scheduling disabled.

[`AkahuItem::SyncRequest`](../../app/models/akahu_item/sync_request.rb) configures the
shared [`LegacySyncRequest`](../../app/models/provider/account_data/legacy_sync_request.rb).
The command pins the original item/family/actor and rechecks the exact control and
connection mapping before queuing the current owner. Existing pending runs are
prelocked without waiting before entering the shared queue operation. Transitional ownership refuses
both writers. Legacy catalogs/settings exclude unavailable migration owners;
stale browser forms receive a sanitized refusal. These filters are presentation
only; command admission remains authoritative.

## Validation and remaining scope

New tests exercise real permits, importer/snapshot races, both token changes,
paginated and empty responses, malformed posted/discovery responses and money,
protected financial rows, receipt expiry, source-policy refusal, transaction
rollback, current Sync cancellation and second-session drain/contention. Existing
transactional fixtures replace only the physical permit and transport-outside-
transaction assertion; separate admission
suites retain the real boundaries. These suites have not been executed here.

Lifecycle and browser suites additionally cover real GET-to-signed-POST flows,
actor/target/cache changes, exact provider routing, blank credential preservation,
per-account permissions, atomic setup/unlink rollback, contended Sync reuse and
deletion dispatch after commit and permit release. Adapter/settings regressions
cover migration-state filtering without changing provider readiness.

Generic direct SQL/model mutations are not made safe by these entry-point wrappers.
[Native Akahu configuration, shared account setup and saved-route retirement](akahu-native-lifecycle.md)
now have separate implementation and authored tests, with readiness still false.
Idless financial identity
disposition and the remaining investment/history/parity gates in
[Akahu cutover history](akahu-cutover-history.md) remain required. No migrations,
live cutover, disconnection or provider activation were performed.
