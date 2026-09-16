# Deferred provider work

Status: the shared continuation and execution-recovery protocols and behavioral
tests are written but have not run in Rails/PostgreSQL. The additive migrations
have not been executed. This
protocol does not activate any provider or complete its export/archive integration.

An asynchronous reader returns an incomplete `Page` with a durable
`progress_cursor`, no immediate `next_cursor`, and an ISO8601 `available_at` in
coverage. The shared runtime validates the response before capture, stores its
encrypted evidence and progress under the connection fence, then raises a typed
`DeferredPage`. `Sync` commits its waiting state under the original execution
lease, then releases that lease. Preparation is a waiting condition and does not emit a failure diagnostic.
Malformed responses and exhausted provider poll budgets remain errors.

`Sync` returns to `pending`, persists `resume_at` and increments `provider_attempt`,
then schedules the same Sync UUID through Active Job after the transaction commits.
No worker sleeps and no database transaction spans the upstream wait. Early or
duplicate jobs cannot start a future or already-running attempt. A resumed attempt
retains the original creation/observation time; providers separately receive the
current request time for polling readiness. A continuation must remain within the
existing 24-hour stale-sync boundary and at most 1,000 deferrals. A later sync
request can requeue a due continuation if its original delayed job was lost.

The requested window freezes when provider work starts. A request for a wider
range creates a successor Sync with a foreign key to the preceding run of that
same connection. Requests can still expand an unstarted successor. The successor
cannot start until its predecessor is terminal; a terminal transition enqueues
it after commit, including when cleanup marks its predecessor stale. It has its
own Sync identity and cannot inherit the prior run's completed-stream evidence.
The existing run's window, cursor and observation date remain unchanged.
For shared providers, a missing requested start means configured/checkpoint
history, not unlimited coverage. Coalescing an unstarted request retains the
earliest explicit backfill; a frozen default request conservatively queues an
explicit backfill whose coverage it cannot prove.
Queue selection follows predecessor relationships even when creation timestamps
tie. A partial unique index permits at most one uncancelled, incomplete successor
per predecessor. Terminal callbacks also tolerate a later diagnostic save in the
same transaction; they do not depend on that final save retaining a status diff.
Committed transitions can re-enqueue an already queued pending successor safely,
while rolled-back transitions enqueue nothing. Real-commit tests cover these
boundaries but have not been executed.
An eligible successor that encounters its predecessor's still-active connection
lease defers before adapter construction. It retries at the earlier of lease
expiry and 15 seconds; cancellation or stale marking does not imply the physical
worker has already released its lease. Removing otherwise removable sync context
cascades through same-owner successors, while batch/generation evidence still
prevents deletion through existing foreign keys.

Ordinary captured-page keys include the attempt after the first deferral. The old
attempt's evidence stays immutable; the new attempt starts from saved fetch
progress. Streams already completed by this Sync are reused, including every
captured inventory page. A newer sync's applied data rejects the older continuation
before another fetch and again before publication. Connection-wide transaction
generations retain their separate seal/child/cursor protocol.

A deferred account does not schedule materialization until its streams finish.
A provider's other account children can finish while their parent is still dispatching
or waiting. `provider_work_finished_at` prevents that child completion from
prematurely completing the provider. Only the running attempt can set that marker;
an old attempt's ensure block cannot complete a newer attempt. Pending parents do
not run post-sync work. Cancellation prevents new continuations and includes an
ancestor's cancellation request; an already stale sync cannot be revived. Existing
family/account completion, cleanup and failure handling otherwise remain in place.
Provider admission checks ancestor cancellation before starting, including a
successor delivered while cancellation is still walking the family tree.
Child creation and direct provider cancellation share the provider Sync lock, so
a cancellation cannot finish scanning its descendants just before another account
child is added. Existing family fanout's broader ancestor cancellation protocol
still needs its separate concurrency acceptance checks.

Export identity is an additional requirement. A saved cursor into a statement,
portfolio or wallet snapshot must restore that exact immutable artifact, scoped to
the family, connection and original sync, with its digest and observation date.
Fetching a new export cannot supply the missing half of an old snapshot. IBKR's
archive and historical-equity handoff implement this separately from scheduling.
Provider-specific preparation, quote collection and multi-topic barriers still
need their acceptance checks before activation.

## Interrupted executions and finalization

`Provider::AccountData::SyncExecution` admits a native job under Connection then
Sync row locks. Starting the Sync, incrementing `provider_execution_revision` and
binding the connection's lease to that exact Sync commit together. `Syncer` borrows
this lease; it does not acquire a second lease or release it before the job can
settle its state. No row transaction spans an upstream request.

The execution revision is distinct from `provider_attempt`. Recovery of an expired
worker retains the Sync UUID, attempt number, frozen dates and captured batch and
generation identities. It changes the live lease owner and connection writer epoch.
Only an unfinished `syncing` row with its exact expired lease may resume fetching;
an absent or foreign lease is not ownership proof. Old unbound runs require an
explicit disposition. Ordinary deferral still increments `provider_attempt` and
resumes from its saved progress. Terminal rows never resume provider fetching.

The original execution token guards failure/deferral transitions, work completion,
credential access and rotation, publication and final child dispatch. An obsolete
worker cannot settle a replacement worker's Sync or clear its lease. If a worker
loses its lease, its error handler leaves the run for recovery rather than marking
the replacement failed. An exceptional interruption which never returns provider
work cannot set `provider_work_finished_at`. Actual takeover and concurrent
cancellation/credential scenarios remain executable acceptance requirements.

The existing cleaner schedules up to 100 recovery candidates per sweep. Expired
unfinished leases are candidates; marked provider work is considered only when
its children are terminal. Duplicate queued jobs recheck admission. Twenty-four
hour stale cleanup uses the same Connection → Sync lock order and fresh state,
invalidates the old execution revision and clears only that Sync's bound lease.
The existing cleaner cadence still determines recovery latency.
Missing connection owners are excluded from recovery scheduling. A queued orphan
is failed, or marked stale by age-based cleanup, under a fresh Sync lock without
provider access or invented completion markers; parent status can still propagate.

Once `provider_work_finished_at` is present, retries only attempt finalization.
They do not build an adapter, refetch data, claim a lease or increment the writer
epoch; pending investment children retain their original input proof. Completed or
failed native jobs can similarly retry unfinished post-sync work without reopening
financial ingestion. `post_sync_completed_at` and database post-sync effects commit
together under the Sync lock and a savepoint. An error rolls them back for retry;
parent propagation still occurs for already-marked children. External broadcasts
may repeat after rollback and are not an exactly-once delivery contract.

Migrations `20260915210000_bind_provider_execution_leases.rb` and
`20260915230000_add_post_sync_completion_to_syncs.rb` define these fields and lease
ownership constraints. They have not run. This protocol does not supply missing
upstream snapshots or make every provider's mid-stream input recovery acceptable;
provider-specific replay, child-input and migration acceptance remain gates.

[IBKR's handoff](provider-ibkr-export-protocol.md#sealed-account-scheduling) now
keeps the same equity capture and account child across worker changes, including
a crash before enqueue. Native historical publication requires the original
request grant and the exact selected sealed account input. Older snapshots without
that proof retain strict epoch checks. The focused integration tests remain unrun.
