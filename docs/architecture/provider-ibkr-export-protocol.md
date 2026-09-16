# IBKR export restoration and historical handoff

Status: the versioned export, archive resolver, equity capture, typed handoff and
sealed account execution integration are written with unrun behavioral tests.
`native_ready?` remains false. No migrations, PostgreSQL trigger installation or
provider activation have run; runtime and financial parity acceptance are pending.

Legacy cached row fields, logo attachments and retained Sync history have a
separate [auxiliary transfer inventory](provider-ibkr-auxiliary-transfer.md). That
copy does not reconstruct XML that the old importer discarded or manufacture a
native export from parsed legacy caches.

## Restoring one provider sync

The shared runtime supplies the original provider sync explicitly:

```ruby
adapter = Provider::AccountData::Registry.build(
  connection, sync: provider_sync, observed_at: provider_sync.created_at
)
```

IBKR requests the `ibkr_export` runtime snapshot. Its allowlisted collector,
`Provider::AccountData::Ibkr::Archive`, reads only that connection, family and
provider sync's captured `accounts` batches. It does not select a latest export.
Request and pending-poll response XML is ignored as an artifact. Ready pages from
the earlier unscoped staged protocol fail closed rather than acquiring invented
provenance.

The first ready inventory slice stores a versioned `ibkr_export` envelope inside
the encrypted canonical page evidence. It contains the original XML, SHA-256,
family, connection, provider-sync ID, observation timestamp, timezone and derived
observation date. Later slices contain the same envelope without the XML. Matching
duplicate captures are tolerated; missing original XML or disagreeing envelopes
block restoration. Archive traversal first reads only IDs and PostgreSQL storage
sizes, with a 1,024-batch limit and a 96 MiB aggregate encrypted-storage budget.
It then loads batches individually and limits the aggregate decoded canonical
JSON to 64 MiB, independently of the XML parser's 32 MiB per-export limit. These
budgets include pending pages, references and every duplicate artifact; matching
duplicates do not grant an unlimited replay allowance. Only the first identical
XML artifact is parsed. Crossing a budget blocks restoration for review; it never
truncates the archive or selects one of disagreeing exports. These are input-size
budgets, not a promise that Ruby object allocation stays below the same byte count.

Restoration happens when building the adapter, before the runtime may replay
inventory batches without calling `list_accounts`. This ensures the statement is
already available to subsequent balance, holding and activity readers. If the
archive contains a ready export, replaying its earlier poll cursor does not poll
again. Inventory and activity continuations bind the exact digest and scope.
Account records also retain the export's sync ID, so identical bytes from a
different sync cannot authorize an old account record.

`observed_at` remains the provider sync's original creation time. RuntimeContext
supplies a separate `current_time` for polling delays; worker resumption never
changes the financial cutoff to make a timer advance. A timezone change during
the run fails the frozen-scope check and requires explicit handling. A newly
created provider sync has no archived export, even if its timestamp matches the
previous sync. Unfinished cursors from another sync fail closed. Only a completed
activity checkpoint may start a new export, reading its first activity again by
stable source identity.

## Capturing and handing off equity

After the source account's streams have been applied, obtain the exact original
inventory artifact ID and derive the account's equity source under the current
provider fence:

```ruby
archive = Provider::AccountData::Ibkr::Archive.build(
  connection: connection, sync: provider_sync,
  observed_at: provider_sync.created_at
)

handoff = Provider::AccountData::Ibkr::EquityCapture.new(
  connection: connection, sync: provider_sync,
  source_batch_id: archive.fetch(:source_batch_id),
  external_account: external_account,
  writer_epoch: current_writer_epoch, fence: method(:fenced)
).capture!

Account::SyncQueue.new(external_account.current_account).enqueue(
  parent_sync: provider_sync, handoff: handoff
)
```

The capture reads the named artifact, validates all same-sync envelopes, derives
the normalized current balance and complete equity section from that XML, and
creates an encrypted `equity_snapshots` batch. Its payload retains the original
inventory batch ID and payload digest, provider-sync ID, account-link ID and link
revision. The handoff also names the exact equity batch, its digest, historical
source-policy revision, account, currency observation date and writer epoch.
No network, FX or financial-record writes occur during capture.

A retry under a later lease epoch reuses the same equity batch from the exact
original sync artifact. Its capture key excludes the worker epoch; the evidence,
handoff and historical commands keep their original captured epoch. Repeating
the handoff reuses the same sealed account child, including when the worker dies
after source capture but before the first enqueue. A changed account-link revision requires a new derived
capture, and the history planner also checks that binding before preparing rows.
Active and retired migration states both retain native authority; quiescing,
rollback and legacy-owned states do not.

At the account execution boundary, resolve the stored input against the exact
parent provider sync:

```ruby
inputs = Provider::AccountData::Ibkr::EquityHandoff.load(stored_input).resolve(
  account: account, provider_sync: original_provider_sync
)
plan = Ingestion::HistoricalBalances::IbkrPlan.new(
  **inputs, capture_revision: account_sync.id
)
```

Resolution rechecks tenancy, linkage revision, source selection, connection state,
captured epoch, both captured payloads and the XML observation scope. The planner/writer
then use the two phases in [historical balance commands](provider-historical-balances.md).
Do not attach this value through mutable `sync_stats`, overwrite an executing
sync's input, or infer a source from the most recently created batch.

## Sealed account scheduling

`Account::SyncInput` persists the encrypted typed handoff per sync/resource. The
queue seals its complete input digest, parent, predecessor and date window before
enqueueing. Database triggers reject changes or additions after sealing. Inputs
and FX preparations can only be deleted with their owning execution. An exact
provider handoff reuses its original child; an ad hoc request can reuse an
identical pending calculation. A running account calculation always gets a
successor, and different provider parents never share a child barrier.

Pending jobs also have sealed windows: only an identical window/input set can be
reused. Unlike the prior queue, a wider or different date request does not expand
an existing pending window. Rapid edits across dates can therefore queue multiple
calculations, even before the first worker starts. Measure that workload before
activation; a later optimization would need an explicit unstarted supersession
protocol that preserves parent barriers and immutable evidence. Scheduling
throughput is not claimed to be unchanged.

`Account::SyncExecution` holds a PostgreSQL session advisory lock across market
data preparation, financial publication and finalization. A busy worker requeues
instead of entering the calculation. A crashed `syncing` job can resume once its
former database session releases that lock. Immutable `Account::SyncPreparation`
retains captured trade FX, and a committed materialization marker prevents replay
from overwriting the same result. Opening repair, normal materialization and
equity history commit together under source and financial row locks.

For ad hoc recalculation, `Account::SyncSource` names the input selected when the
provider queues its handoff. The new job copies that exact payload under the
account lock, including when an older calculation is running. Selection does not
imply successful materialization; the job rechecks the policy, link and original
source before writing. It never orders equity batches by creation time. `Sync#retry_account_later`
copies the failed job's original input even if the selected source has changed.
For native artifacts with a complete captured `RequestGrant`, every child,
planner and writer requires the exact currently selected sealed input. This
also permits ad hoc recalculation from that still-selected original source
after another provider worker epoch begins. A replaced selection rejects the
old input even if the worker epoch is unchanged. The original grant must still
match credentials, configuration and authorization; observing a newer credential
revision does not authorize adoption of it.

The pre-enqueue capture has a separate boundary: the current provider execution
fence must own the exact original Sync and artifact. It may reuse a source whose
child was never created, but cannot replace a later selected source from the
same connection. Source epochs from different connections are not ordered.
Capture and publication acquire the original grant's connection, provider Sync,
family/settings and declared account locks before financial Account/child locks.
Those locks remain held through publication; no network calls occur within them.

Compatibility is explicit: older or standalone snapshots without full request
evidence retain the strict requirement that captured and current epochs match.
They cannot use the selected-input exception. A malformed or incomplete supplied
grant fails verification rather than falling back to compatibility mode. No
other provider's history protocol gains cross-epoch permission from this change.
Captures created under an earlier experimental idempotency-key format require
explicit migration review; this change does not rewrite their keys or handoffs.

The shared Syncer now invokes `Ibkr::AccountHandoff` after complete inventory and
all required account streams. Failed/deferred streams and cancellation do not
schedule an IBKR materialization from a partially imported export. Other provider
dispatch behavior remains unchanged.

Behavioral tests cover stable replay before and after child enqueue, retained
source/command epochs, credential rotation and same-epoch source replacement,
as well as sealed queueing, ad hoc selection, retries, cancellation,
source drift, busy execution, missing FX rollback and ordered materialization.
They have not run in this environment. Verify crash recovery between artifact
capture, account-stream application, handoff persistence, account execution claim
and each historical phase before activation. Deployment must drain old workers
that do not hold the account execution fence. Provider activation remains blocked
on Rails/PostgreSQL integration and financial parity tests.
