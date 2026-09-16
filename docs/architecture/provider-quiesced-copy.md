# Quiesced provider copy preparation

Status: written with unrun Rails/PostgreSQL tests. This is a preparation primitive
for the [migration plan](bank-data-provider-migration-matrix.md), not an activation
command or a completed provider migration. No copy, schema migration or cutover has
run in this workspace.

## Ownership across bounded passes

`Provider::AccountData::MigrationCopier#run` keeps its existing shadow-copy role.
Legacy writers remain authoritative during that comparison. It refuses to run
when the control is `quiescing`, even when called on an instance that previously
held the copy lease; rejected calls cannot change the control through error cleanup.

`run_quiesced` acquires `LegacyWriterFence.with_exclusive` for the exact legacy
item before creating or locking the control or entering any database transaction.
It cannot upgrade an active legacy write or run inside a caller's transaction.
An admitted legacy writer prevents acquisition, including before a control exists.
A live ordinary copier lease also prevents takeover.

The initial transition from a legacy-owned state sets `quiescing`, invalidates the
old audit and starts a new copy run with a fresh ID and watermark. Subsequent calls
reacquire the same exclusive fence and continue the persisted copy/verify phase.
Each call processes at most the configured number of source accounts. Existing
per-row payload materialization can be large; this is not a total time/byte bound.

The control stays `quiescing` between calls, after successful verification and
after copy failures. Declared legacy writers and family scheduling cannot resume
it merely because a copier releases its session lock or its lease expires. Native
connections remain disabled. An expired lease allows another copier to resume;
the new owner must recheck the current state and preparation protocol first.

Source changes detected during verification restart the comparison and clear its
audit. Other failures retain the committed watermark and clear successful audit
claims, while preserving the original exception. Captured typed snapshots remain
encrypted; retries retain mapped target IDs and existing AccountProvider UUIDs.
This path performs no ledger writes, provider HTTP, credential exchanges or
destructive source callbacks.

## What the result proves

A completed pass has watermark phase `verified` and remains `quiescing`. Its audit
records the run ID, item/account/link verification scope and that the declared
legacy writer fence was held during each pass. It deliberately still records
`source_quiesced: false` and `requires_cutover_reverification: true`.

The existing fence does not cover every direct writer, lifecycle action, generic
Account/AccountProvider change or old deployed worker. Row verification spans
separate transactions and calls; it is not a universal point-in-time database
snapshot. An uncovered writer can alter an earlier verified row. Complete and
deploy the [legacy boundaries](legacy-writer-fencing.md), drain old workers, and
coordinate those operations before treating the comparison as stable.

Calling `run_quiesced` after phase `verified` reuses the completed pass; it does
not claim a fresh comparison. `run_quiesced(restart: true)` explicitly invalidates
that pass and starts again without reopening legacy admission. Use that option
only to begin the new pass; ordinary subsequent calls resume its progress. Neither
method translates native checkpoints, publishes migration identity evidence,
verifies auxiliary copies or switches writer ownership.

## Verifying the retained copy after identity publication

Once financial identity evidence exists, changing the original copy run or its
archives could invalidate that evidence. `verify_retained_quiesced_page` provides
a separate, read-only comparison against the retained copy:

```ruby
copier = Provider::AccountData::MigrationCopier.new(
  provider_key: provider_key,
  legacy_item_id: legacy_item_id
)
page = copier.verify_retained_quiesced_page(
  family: authorized_family,
  cursor: nil,
  limit: 100
)
```

The reader acquires the exact exclusive session fence before its database
transaction. It requires the original verified quiesced copy, matching audit/run,
zero epochs, a disabled unused connection, no live copy lease and no native work.
Only this reader admits the existing `legacy_financial_identities` checkpoint
alongside the previously allowed migration streams. It never calls a copier
mutation, changes mapping timestamps, recopies credentials, rewrites archives or
advances any checkpoint. Failures leave the retained audit and progress untouched;
support diagnostics contain only scope IDs, operation and error class.

Every page compares the current item and its authorization, if applicable, with
the exact typed encrypted archive and target projection. It then verifies at most
500 source accounts, including sensitive fields, cached state, external-account
ownership, authorization membership, legacy checkpoint state and financial links.
Selected verification queries reject rows larger than 32 MiB and limit archive
reconstruction to 32 MiB/1,024 chunks. Initial item admission through the existing
fence still materializes the item before that preflight, so these limits are not
a complete pre-materialization memory or total page latency guarantee. Row locks
use NOWAIT when acquiring item/account/source/link/authorization rows so active
edits can defer the comparison.

Forward and reverse inventory queries require the current source accounts, exact
typed mappings and shared external accounts to agree. The initial copied grant
and its active memberships must also match the manifest's exact authorization
topology; unexpected grants or memberships stop verification. They include unlinked
sources and catch missing/new accounts even behind a cursor. Each immutable row
result identifies the mapping, source checksum, source/target UUIDs and a `linked`
or `unlinked` disposition. A linked result includes the retained AccountProvider
UUID/revision and financial Account UUID. An unlinked source has no financial
bootstrap to publish; it must remain explicitly accounted for by the coordinator.

The continuation pins the authorized family, connection, copy run, item archive,
credential revision, region/environment, source count and page size. Pass the
returned `next_cursor` to a fresh reader with the same parameters to continue.
These read results are not signed authorization and cannot prove that a caller
visited all earlier pages. `complete` only means this enumeration reached its end;
the context explicitly retains `requires_cutover_reverification: true`.

The [preparation coordinator](provider-migration-preparation.md) now selects its own
cursor, retains every linked/unlinked mapping and combines fresh copy and financial
identity sweeps. Auxiliary and native-checkpoint acceptance remain separate work.
Existing account data can change after its
page is checked if a writer does not participate in the fence. This reader does
not resolve that remaining deployment/lifecycle drain or activate a provider.

### Original financial-account binding

Every newly copied account archive retains an `account_binding` alongside its
complete source columns. This records the final AccountProvider UUID, provider
and financial-account references, family, external-account reference and link
revision, plus the financial Account's UUID, family, currency and delegated type
identity. An unlinked source records explicit nulls. The binding participates in
the archive checksum and encrypted chunks; it cannot be replaced by today's link.

Both ordinary copy verification and retained verification compare this original
binding. They reject a same-family relink, a removed/replaced link, a newly linked
source or changed financial identity/context, even when all current associations
agree with each other. Legitimate balance, description and user-protection edits
do not change this binding. Identity planning and permanent evidence publication
also check it before assigning original financial UUIDs to a source.

Older account archives without the binding do not establish original ownership
and cannot pass these verification paths. Before permanent identity/preparation
evidence exists, an eligible new full copy may capture it under a new checksum,
preserving the older chunks. After evidence exists, explicit reconciliation is
required; the missing binding cannot be filled from the current account or inferred
from a later preparation receipt. These safeguards have unrun regression tests.

### Coinbase's derived monetary view

Coinbase source quantities and native monetary values are different fields. When
the legacy wallet lacks a native amount, copying can derive its monetary value
from the linked financial account; even a supplied native amount can use the
linked account's cash balance. Recomputing that view after a legitimate user
balance edit would compare against a different point in time.

New Coinbase account archives therefore include an optional `derived_projection`
alongside the complete typed source row. The same encrypted, HMAC-checked archive
retains the exact assigned queryable target attributes, final AccountProvider
identity/revision and financial Account identity, currency and delegated type.
It does not use the current target as its own verification baseline. A new copied
projection receives a different checksum/chunk identity; older archives remain.

Retained verification compares every original source field and checks the current
link/account context, then compares target attributes to this captured projection.
Later balance/cash edits to the financial Account are allowed; source, copied
target or identity/context changes are rejected. Ordinary initial copy verification
still checks the then-current fallback, preserving its existing acceptance rule.
Older Coinbase archives without this baseline require explicit reconciliation;
the reader cannot reconstruct missing copy-time amounts from today's ledger or
silently recopy after permanent financial identity publication.

## Returning to legacy operation before activation

`resume_legacy!` acquires the same exclusive fence, reloads the exact family/item
control and only accepts this copier's `quiescing` preparation protocol. Within a
short control/connection transaction, it rejects a live copy lease, nonzero
control or connection writer epoch, enabled connection, any connection writer
lease, unfinished credential intent, any native Sync or non-migration batch, and
any checkpoint outside the explicitly allowed migration streams. A copied
credential revision may legitimately be positive after a legacy token changed;
the revision alone is not evidence that the native provider has run.

Retained financial identity batches or bootstrap EntrySources also prevent
resumption and restarting the copy, independently of their checkpoint. A missing
checkpoint must not reopen these paths or permit replacement of the original
copy context. Recover that evidence explicitly; deleting progress is not rollback.
Retained connection or account preparation progress now also prevents these paths,
including before the first identity batch and when no financial entries exist.

Eligible resumption returns ownership to `legacy`, clears the watermark/audit and
retains the disabled target, encrypted snapshots and dual account links. It does
not restore archived credentials into the live source. Existing effective-provider
selection resolves those links through their legacy side. The next final pass
must copy and verify all rows again; old mapping timestamps cannot authorize it.

This is not post-activation rollback. Once native state, signed requests or token
rotation exists, reverse transfer needs its own protocol. No flag flip may revive
stale legacy cursors or spent tokens. These methods are internal and are not
exposed through the operator copy task or background job. Durable handling of
requests arriving during quiescence and atomic activation remain integration gates.

## Verification

`test/models/provider/account_data/migration_quiescence_test.rb` exercises:

- Existing shadow invalidation, fresh credential copying and unchanged financial
  accounts, entry IDs and dual-link UUIDs.
- Real-session exclusion during a pass and denied legacy admission between calls.
- Ordinary copy rejection, copier lease recovery and fresh-instance continuation.
- Failed/interrupted copies, source-change restart and explicit fresh comparison.
- Pre-native resumption and rejection of native-use indicators or another protocol.

Run this suite with the existing copier, migration job and legacy-fence suites
against the additive schema in Rails/PostgreSQL before enabling the preparation
path. Those tests have not run here. Full-provider parity, auxiliary transfer,
source authority, native checkpoint/identity bootstrap, lifecycle drain, activation
and rollback acceptance remain separate requirements.
