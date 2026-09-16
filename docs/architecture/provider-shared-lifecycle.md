# Shared legacy lifecycle admission

Status: admission boundaries and regression tests are written. Tests have not
run in this workspace. These boundaries prepare legacy operations for incremental
cutover. [Native account unlink](provider-native-account-unlink.md) now has a
separate shared admission path; family-data retirement remains unfinished.

## Operations spanning several providers

`LegacyWriterFence.with_items(items, operation: :lifecycle)` acquires the complete
declared item set on one database session before opening a write transaction.
Inputs must be persisted manifest-backed items from one family. Duplicate
identities are collapsed and locks are acquired in deterministic type/UUID order.
Every requested item must still be owned by its legacy implementation before the
operation block runs. Partial acquisition or failed ownership checks release all
acquired locks; an uncertain acquisition/release disconnects the session.

The block receives a frozen array of fresh item receivers. Nested item calls and
subset calls retain each member's own receiver and recheck the requested members.
They cannot add another item or switch to the migration-exclusive mode. Rechecking
only requested members permits a family deletion to process another item after an
earlier admitted item has been deleted. An empty set still prevents later widening;
because it acquires no advisory locks, it may enter an existing transaction.

These shared permits exclude exclusive migration drains. They do not exclude
other legacy workers or account edits. Each aggregate operation must therefore
lock its financial owner, lock the relevant source/link rows, and repeat its exact
inventory before making changes. If the inventory differs, restart admission from
outside the transaction; never add another lock while partway through deletion.

## Generic account unlink

`Account::Unlink` moves the existing controller operation behind model-level
admission. The compatibility-only `LegacyAccess` inventories all current AccountProvider tuples,
direct Plaid/SimpleFIN references, source-item ownership and copied external-account
mappings. A dual link must describe the same legacy source and migration control
on both sides. Unknown/missing/foreign sources and native-only/native-owned links
are rejected before mutation. The public command now uses `Access`, which admits
native and mixed source sets as described in [native account unlink](provider-native-account-unlink.md).
The following cleanup rules describe its legacy-owned members.

After the complete item permit is held, the access boundary locks the financial
Account, item/source rows, external accounts and links. Contention on these locks
defers the operation; a fresh inventory must exactly match the original selection.
The unlink command rechecks the active caller's account access and management
permission against current state, with nonblocking actor/owner and share locks.
It rejects a selected link whose source-policy revisions are referenced by retained
ingestion batches, including historical commands' secondary policies; unknown
historical routing also prevents detachment. Fully captured selections without
those references are deactivated and retained, never cascaded with the link.
Unknown policy bindings require disposition. It validates holding ownership before detaching holdings
from the selected provider links, removes links atomically, and clears direct FKs.

Existing cleanup distinctions remain deliberate: ordinary provider source rows,
including Plaid and SnapTrade, survive; CoinStats/Onchain link callbacks remove
their tracking rows; a directly referenced SimpleFIN row is removed after its FK
is cleared. An AP-only SimpleFIN row follows the existing preservation behavior.
Financial transactions, holding quantities and amounts are retained. Failed cleanup
must roll back unlink rather than report success with an orphaned tracking row.
The access boundary uses a savepoint so an already admitted outer caller cannot
commit partial cleanup after handling an unlink failure.

This inventory covers unlinking current links. It is not an Account destruction
boundary: destruction can mutate transfer counterparties, fee transactions and
retained source evidence even after provider links have gone.

## Family destruction

`Family::LegacyDestruction` inventories all 23 manifest item classes by family,
including ignored, disabled, unlinked and scheduled-for-deletion items. It acquires
the complete permit before Active Record's dependent callbacks or remote cleanup.
Under the Family row lock and item row locks it repeats inventory and ownership
checks before allowing destruction to proceed.

Before item locks, it also takes nonblocking User and Account locks in UUID order.
These reject competing family transfers and account materialization before remote
callbacks, including the Account key-share lock held by a balance insertion.

Existing restrictions on shared connections, migration controls/mappings and
ingestion batches, including file-only evidence,
are checked before Stripe/Plaid or other irreversible callbacks. Rejection retains
the family's errors/false result rather than partially running cleanup first.
An aborted destroy rolls back its database work through a savepoint. This does not
make remote callbacks transactional; their successful-path ordering remains an
existing lifecycle behavior requiring acceptance.
See [Family destruction admission](family-legacy-destruction.md) for the exact
lock order, retained-data restrictions and coverage.

## Remaining cutover requirements

Direct financial Account destruction/scheduling and its failure recovery still
need complete ownership admission, including transfer counterparties and detached
evidence. Generic AccountProvider mutations, family financial-data reset, source
creation/reparenting, remaining provider-specific settings/credential consumers,
[native local disconnection](provider-native-disconnect.md), upstream revocation
and retained-data deletion also require their own coverage. The shared local
disconnect command and its review/receipt path are now written; runtime acceptance
and remote revocation remain outstanding.
Shared permits alone do not serialize concurrent legacy publication and unlink.
SimpleFIN's link repair now checks the current direct FK and locked link inventory,
and its transaction entry processor uses a short locked publication command that
retains the selected financial owner through the write. Other direct writers still
need fresh source/link checks at publication; the unlink inventory does not by
itself drain all legacy processing. Generic link mutations need outer admission
covering both the old and proposed source owners before Rails opens a transaction;
a model callback that acquires the advisory permit would run too late.
Runtime concurrency tests, deployment of all legacy boundaries, old-worker drain,
native checkpoint acceptance and atomic activation remain mandatory. No provider
cutover follows merely from passing an unlink or family-deletion test.

The Account deletion audit must include scheduling and recovery, not only
`destroy`: [Account](../../app/models/account.rb) marks `pending_deletion` before
enqueue, while [DestroyJob](../../app/jobs/destroy_job.rb) currently admits provider
item/account classes but not financial Accounts. The affected graph includes
transfer counterparties, fee entries, split descendants and the matched
transactions changed by [GoalPledge](../../app/models/goal_pledge.rb) cleanup.
Account-level SourceRecord destruction previously removed retained evidence before
Entry's archive callback could preserve it; the new identity guard now refuses
that path. A missing current provider link does
not prove that no copied context refers to the Account: the original financial
UUID can survive solely inside encrypted migration archives. Admission needs a
verified reverse inventory before any destructive callback or recovery status
change. The [retained account index](provider-retained-account-index.md) now
captures each archive version's historical financial/link UUIDs and explicitly
indexes unlinked copies. Copy/preparation verification checks for unresolved
chunks; existing copies have a bounded explicit backfill. Tests are unrun, and
Account destruction still needs to consume this index alongside the current
financial graph and native evidence under complete ownership admission.

The read-only `Account::Destruction::Effects.capture(account:)` now inventories
recursive split and transfer-fee deletion, surviving transfer counterpart edits,
pledge matches, rejected-transfer ownership witnesses and statement headers. Its
deeply frozen proof contains scalar identities and PostgreSQL row versions, not
financial amounts or provider payloads. Missing/ambiguous ownership, cross-family
edges, cycles and exceeded limits stop capture. The limits are 10,000 aggregate
rows, 100 accounts and depth 32; these can reject realistic large histories and
require performance acceptance before a public deletion command relies on them.
This provisional graph omits the wider dependent-row/provider-owner inventory,
does not acquire locks and grants no deletion permission. It must be recaptured
after complete admission and locking. Tests are written but unrun.

Native generations also retain detached bindings before account-batch fanout.
The [generation account index](provider-generation-account-index.md) preserves
these original UUIDs for reverse discovery, with explicit unknown versus empty
states and bounded backfill. Full source discovery must still include policy-only
batches, superseded Account Sync inputs and document/import owners; neither index
nor the financial graph has yet been wired into Account destruction.

[Account source discovery](provider-account-source-inventory.md) now combines
these paths into a provisional scalar inventory, including native and dual owners,
policy-only equity captures, superseded calculation inputs, Sync lineage and
document/import contexts. A read-only operator task exposes its owner summary.
[Historical command bindings](provider-historical-command-bindings.md) now retain
both original policy owners, including a different source for current balances.
New captures and retries populate the projection; cold older rows require explicit
backfill. Missing or deleted policy references remain unresolved. A native deletion
command now has [retained financial identity groundwork](provider-retained-financial-account.md)
that preserves the original UUID independently of the live Account. Capture and
database retirement constraints are written; Account destruction refuses evidence
before callbacks. [Source-policy retention](provider-source-policy-retention.md)
now preserves the selected source tuple independently of live links, including
verified one-way copier enrichment. [Calculation retention](provider-account-sync-retention.md)
now preserves original Sync ownership and evidence. The full admitted retirement
command, scheduling and recovery remain unfinished. Tests remain unrun.

Generic AccountProvider mutation must cover both persisted and proposed source
scopes, including all dependent callbacks. Migration attachment needs a separate
exact capability: [MigrationCopier](../../app/models/provider/account_data/migration_copier.rb)
can add copied identity fields before saving the account mapping, and ordinary
shadow copying currently does not acquire the item permit. The shared link guard
must not infer permission from mutable control state or require a mapping that
does not exist yet. SourcePolicy's link-family backfill, broad rescue handlers in
legacy link repair, and FinancialDataReset's bulk deletes are explicit integration
points; adding only an Active Record callback would leave these gaps unresolved.

See [legacy writer fencing](legacy-writer-fencing.md),
[source authority](multi-source-ingestion.md) and
[implementation status](provider-implementation-status.md).
