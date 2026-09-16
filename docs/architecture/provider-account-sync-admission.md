# Account calculation admission

Status: fresh-owner admission and publication checks written; behavioral and
concurrency tests remain unrun. This closes worker gaps needed for native provider
lifecycle support. The [ownership migration](provider-account-sync-retention.md)
adds retained history; neither change implements the complete Account retirement
command.

## Queue and execution

[`Account::SyncAdmission`](../../app/models/account/sync_admission.rb) reads the
live Account without using a cached association. Only supported non-deletion
states (`active`, `draft`, `disabled`) are eligible. An existing retained identity
must agree on family, live pointer and non-retired state. Missing, retired,
pending-deletion or inconsistent owners are unavailable. Admission does not
create an identity or reconstruct an Account from historical evidence.

[`SyncQueue`](../../app/models/account/sync_queue.rb) checks the original
account/family before reading selected inputs, retry evidence or a provider
handoff. It repeats admission under Account/identity locks after taking the
required provider-parent locks. An already sealed execution also needs fresh
admission, but verifies its original inputs without consulting today's selection.
New provider handoffs additionally recheck their original live link/revision and
historical policy under the Account lock before selecting a child input. This
prevents a completed capture from reconnecting an account after
[native unlink](provider-native-account-unlink.md) clears its live selection.

[`SyncExecution`](../../app/models/account/sync_execution.rb) retains its account
advisory session lock across execution. Inside a short transaction it checks the
Account before recovering a running Sync or sealing an old queued one. It verifies
the Sync still has the identity for which that session lock was acquired. The
worker receives the fresh Account after the row transaction ends.

An unavailable in-progress execution becomes `stale` with a generic diagnostic.
It does not start work, fabricate an empty input seal, change materialization or
completion markers, run post-sync work, dispatch successors or finalize its parent.
An already terminal execution stays unchanged. Lock-contention retries require a
fresh matching, incomplete, uncancelled Sync and an eligible live Account.

## Publication and finalization

Initial admission cannot cover changes during market-data requests. Calculation
publication therefore rechecks the owner under locks after preparation. Market
data and trade-flow FX acquisition remain outside row transactions. Native
preparation and financial publication retain their provider/grant-before-Account
lock order; calculations use cached exchange rates in their write transaction.
Legacy IBKR overrides require legacy-writer admission before acquiring Account
locks and must still refer to the same financial account. Ordinary, native and
legacy override publication also lock the real child Sync after the Account and
recheck its owner, running status and direct/ancestor cancellation. A worker that
was cancelled or finalized during preparation cannot publish from its old receiver.

Cache-only publication is strict: missing or invalid required FX fails the write
transaction. Ordinary calculations previously could fetch rates during writes or
continue through legacy conversion fallbacks. Complete preparation coverage and
legacy numerical parity must be tested before rollout; these checks do not prove
that every existing multi-currency history can already publish successfully.

Finalization locks Account before its child Sync and checks ownership again before
status completion, transfer matching or the post-sync completion marker. Parent
propagation uses Rails'
[after-all-transactions commit callback](https://api.rubyonrails.org/classes/ActiveRecord.html#method-c-after_all_transactions_commit)
so an outer savepoint cannot retain Account locks while recursively taking the
provider parent's lock. No post-sync work is authorized by a materialization marker
alone. External broadcasts retain their existing possible-repeat semantics after
a rolled-back marker transaction.

## Remaining retention and rollout work

The [calculation ownership migration](provider-account-sync-retention.md) now
captures original family ownership, transfers input ownership to retained Account
identities and rejects retired execution/source deletion. It preserves ordinary
empty-job cleanup. These changes and their tests are also unrun; the admitted
retirement and full native erase commands remain unfinished.

Old executions without live, input or retained-identity proof remain unknown and
cannot execute by adopting today's owner. Retired history is internally visible
through its captured family, while user-facing access still requires a live
accessible account. Family membership cannot recreate deleted shares. Recovery,
retirement's use of the execution session lock, full FX preparation coverage and
provider-specific parity still require acceptance.

See [retained account identity](provider-retained-financial-account.md),
[source-policy retention](provider-source-policy-retention.md),
[shared lifecycle](provider-shared-lifecycle.md) and
[implementation status](provider-implementation-status.md).
