# SimpleFIN direct ingestion admission

Status: implemented boundaries with behavioral tests authored but unrun. No
SimpleFIN connection has been migrated or activated by this work.

[`SimplefinItem::LegacyAccess`](../../app/models/simplefin_item/legacy_access.rb)
admits direct importers and financial processors under the same item permit as
ordinary sync dispatch. It refreshes the source through its original item before
using account links or cached payloads. Supplied Sync records must still belong
to the item and remain eligible. Transport construction occurs after admission;
SimpleFIN requests receive the admitted item's current access URL. The permit
does not open a database transaction around HTTP. Direct access and the full
Syncer also hold the [credential session lock](simplefin-credential-claims.md),
serializing admitted ingestion with reconnect and credential maintenance.

Account, transaction, entry, holdings and credit processors use freshly admitted
source instances. Transaction/account processors retain skipped-entry reporting,
and a shared import adapter must belong to the current financial account and its
currency/delegated type. The importer also re-admits each saved source before
balance, pending-reconciliation, credit, cash or holdings-job effects. It keeps
its own counters and debounce sets across these checks. Sync setup-count merges
reload the persisted stats, preserving discovery's `balances_only` marker and
leaving `last_synced_at` unset for the first full history import.

Fresh, uncached link checks reject conflicting direct FKs and AccountProvider
links, foreign financial families, and another SimpleFIN source occupying the
same financial account. Other providers' links remain valid. A dual legacy/shared
link must identify the exact external account, connection, legacy-owned control
and account mapping. These checks load identity columns rather than decrypting
the control's retained migration documents for each entry.

`ensure_account_provider!` no longer recreates a link from a stale cached account.
It locks the financial account, item, source and existing external/link rows with
`NOWAIT`, rechecks the exact
link inventory inside a short transaction, then returns the existing link or
creates the missing direct-FK link. Returning a locked existing link also prevents
a direct AccountProvider deletion from becoming an unintended repair/recreation.
No financial update or network call occurs in
that transaction. Ownership, invalid-source and busy denials propagate through
processors, importer recovery and stale-link repair. Importer ensure handlers do
not write recovery statistics while those denials unwind.

`with_publication(source, expected_account:)` adds a short local-write boundary.
It retains the previously selected financial Account identity, family, currency
and delegated type, then locks Account, item, source, copied ExternalAccount and
AccountProvider rows with `NOWAIT`. The exact link inventory and financial context
must still match after locking. Fresh source associations point to that locked
Account. A changed or busy owner fails before merchant or financial publication;
the command does not follow a newly selected account after relinking.

The transaction entry processor now uses this boundary per entry, preserving the
existing transaction loop's independent commits. Merchant creation and entry
effects share a savepoint, so an admitted outer caller can rescue a failure
without committing either. Account balance computation, credit attributes,
balances-only discovery and post-import cash refresh use the same boundary.
Credit publication also rolls back when the shared import adapter rescues an
update failure and returns false; a callback failure after SQL cannot leave a
partially saved credit value. Existing false and nil return semantics remain.
Account processing commits its balance before later transaction/investment stages;
it does not retain those row locks through security resolution. Importer ownership
denials now also precede holdings-job enqueue, while ordinary cash-calculation
errors retain the existing job fallback.

Holdings resolve securities first, then recheck the original financial context,
AccountProvider identity/revision and direct FK inside publication. Each holding
has its own savepoint. Existing quantity, cost-basis protection and future-row
preservation behavior remains; this does not assert a complete snapshot or permit
absence pruning. Source/identity lookups and transaction normalization here need
no HTTP; transport and security lookup must remain outside publication. A caller
that opens its own surrounding transaction is still responsible for that rule.

Tests cover balance/credit/holding parity, unlink/relink and currency/type changes
after selection, actual competing unlink admission, direct link-row contention,
downstream stage ordering and rollback after financial work. All remain unrun.

This is not yet a complete lock around every legacy financial publication.
Deferred-job effects still require coordinated publication checks before cutover.
Original enqueue lineage, generic
link mutations and direct private-method callers also require acceptance. Direct source snapshot
setters, stale-link repair as a whole, setup/reparenting, credential edits and
other lifecycle callers also remain separate acceptance work. The
[deferred holdings request](simplefin-deferred-job-fencing.md) now binds its original
owner, inputs, link/policy and Sync ancestry, rechecking before security resolution
and each write. Old ID-only jobs require explicit disposition; execution-day
holdings dates remain acceptance work. Existing-item credential requests now have
[retry and audited cancellation controls](simplefin-credential-claims.md), with
runtime acceptance and initial-connect recovery still outstanding. None of these
legacy commands gains native source authority from admission alone.

## Pending cleanup

The importer now calls [`SimplefinAccount::PendingCleanup`](../../app/models/simplefin_account/pending_cleanup.rb)
instead of the broad `Entry.reconcile_pending_duplicates` and
`Entry.auto_exclude_stale_pending` helpers. Those general helpers remain available
to their other callers; this change does not assert that they have migration
admission. The replacement is deliberately scoped to the currently admitted
SimpleFIN account and cash-source policies.

A compatibility `source` label alone does not prove ownership after relinking.
Both sides of a proposed match must have an unambiguous identity in the current
source's retained transaction cache, including matching amount, currency, date,
name and pending state. The cleanup reuses the entry processor's read-only
identity projection, pins the cache and account type, and checks their stored
representation before each publication. Missing or conflicting cache evidence
stays unresolved. This is source-membership evidence, not proof that an upstream
response is complete.

Each pending row has a separate publication savepoint. Candidate Entry rows lock
in UUID order, followed by Transaction rows; ownership, candidate selection and
protections are checked again. Shared entryables, transfers, split participants,
field locks, import/user protections, reconciliation and any retained EntrySource
history disqualify a row. Copied/native identities are left for the shared
ingestion protocol, including evidence whose live Entry link was detached.

The existing age policy still excludes eligible pending rows older than eight
days; it does not delete them or infer provider removal. Heuristic exact matching
requires uniqueness in both directions. Fuzzy matching remains a suggestion,
requires the same cash direction, and retains its three-day/25-percent bounds.
Other providers, manual entries and excluded/protected rows cannot supply the
matching candidate. This narrow legacy heuristic is not general cross-source
reconciliation or an identity bootstrap policy.

The ownership index admits at most 20,000 retained rows and 16 MiB of stored
payload, including encryption overhead. Oversized or invalid cache shapes produce
a sanitized diagnostic and an incomplete result with no cleanup writes. Source
identities are queried in groups of 100; fuzzy candidate results stop at 101 and
cannot establish uniqueness when truncated. Stored cache bytes are compared
without repeatedly decrypting and normalizing history inside each publication.
Production-size performance and a durable paged history representation remain
acceptance work; these limits are not a claim of measured throughput.

Ordinary row failures escape the savepoint before being recorded, while ownership
and busy denials propagate. Outcomes, counters and the importer debounce update
only after enclosing transactions commit. A failed row or incomplete cache leaves
the account eligible for another attempt in the same importer. Existing suggestions
and already excluded entries do not generate another change count. Remaining stale
rows are reported separately, including protected or unresolved rows.

The [cleanup tests](../../test/models/simplefin_account/pending_cleanup_test.rb)
cover mixed sources, cache membership, protections/evidence, policy selection,
ambiguity, actual SQL/callback rollback, outer transaction rollback, cache bounds
and competing database locks. The
[importer integration tests](../../test/models/simplefin_item/pending_cleanup_integration_test.rb)
cover real cleanup across repeated provider responses and once-only counters.
All are authored but unrun.

The [direct-access tests](../../test/models/simplefin_item/legacy_access_test.rb)
exercise denied ownership states, fresh payloads, stale-link recreation,
conflicting and shared links, different-provider coexistence, reparenting,
shared-adapter ownership, nested denials and real competing database sessions.
The [importer regressions](../../test/models/simplefin_item/importer_admission_regression_test.rb)
cover saved-source admission, recovery writes, counters and discovery timestamps.
Existing financial behavior tests use a fixture-only permit shim while retaining
fresh ownership checks; these nontransactional suites use the actual permit.
