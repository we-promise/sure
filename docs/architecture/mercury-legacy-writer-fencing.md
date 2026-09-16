# Mercury direct legacy publication

Mercury's direct importer, Syncer, account processor, transaction batch processor,
Entry processor and snapshot methods now acquire the same legacy session permit
as ordinary Sync dispatch. They reload their selected item/source after admission.
The importer constructs its client from those admitted credentials; it no longer
accepts a client constructed from an earlier credential snapshot.

[LegacyAccess](../../app/models/mercury_item/legacy_access.rb) retains the permit
across import HTTP and storage, while refusing transport inside a database
transaction. The direct Syncer verifies the original Sync and keeps admission
through child scheduling. Ownership denials escape the existing per-account and
per-entry ordinary failure handlers.

Local balance and Entry publication use short savepoints. They lock and recheck
the financial Account, source item/account, shared external account and selected
AccountProvider before writing. Publication pins family, currency, delegated
financial identity, remote source identity and link revision; a relink after
selection refuses rather than choosing a new financial owner. Shared links must
have the exact retained Mercury control and account mapping under legacy
ownership. Account owner locks use NOWAIT before validations. Ordinary failed
Entry callbacks roll back that entry's merchant and financial effects before the
transaction batch reports its failure.

The [real-session tests](../../test/models/mercury_item/legacy_access_test.rb)
cover direct native/quiescing refusal, fresh credentials, exclusive-drain exclusion
during HTTP, scheduling, receiver reuse, link/currency drift, row contention,
source identity rejection and callback rollback. Existing transactional behavior
examples use an explicit test-only session-permit substitute; the importer unit
suite also substitutes its transport-transaction assertion because all transport
calls there are fakes. Those substitutes are absent from the real-session suite.
Tests are authored but unrun; no readiness flag, migration or cutover changed.

This document describes direct import/publication admission. The subsequent
[lifecycle slice](mercury-lifecycle-admission.md) covers browser settings,
discovery/pickers, setup/linking, manual Sync routing and ordinary legacy
disconnect, including direct deletion scheduling/unlink admission. Retiring a
connection with retained source-policy or dual-link evidence remains separate.
Direct raw item/account destruction is also outside these declared commands.

Legacy ProviderImportAdapter pending reconciliation retains its existing
same-account, potentially cross-provider behavior. This permit does not authorize
multi-source reconciliation or establish native source-selection policy. Mercury
still needs its own cached-row disposition and account-scoped first-history input,
source selection before identity publication, and reviewed final cutover
integration. Up's history rules must not be copied blindly: Mercury's legacy
empty-cache window uses the later of account creation minus seven days and ninety
days ago, while nonempty caches use the last completed legacy Sync minus seven
days when available. Archive or identity retention alone proves neither that the
latest cached version was applied nor that upstream history is complete.
