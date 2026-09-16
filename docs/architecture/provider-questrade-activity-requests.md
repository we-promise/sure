# Questrade deferred activity requests

The legacy activities job now has durable account-local request ownership. This
is transitional infrastructure for draining legacy work before native handoff;
native syncs retain their shared continuation protocol. Implementation and focused
behavioral tests are written but unrun. The additive migration has not executed,
and Questrade native readiness remains false.

## Persist the request before dispatch

The additive `RetainQuestradeActivityRequests` migration adds an encrypted
`activities_fetch_request` document, a monotonic `activities_fetch_revision` and
an indexed `activities_fetch_due_at` to `questrade_accounts`. The existing pending
flag remains a compatibility projection of active request state. An old pending
flag without a document is explicitly unknown work, not an empty queue.

`QuestradeAccount::ActivitiesRequest.enqueue` captures the original item/family,
provider account and remote identity, financial account/currency/type, exact
AccountProvider UUID/revision, and optional Sync ancestry. After the surrounding
credential operation succeeds and releases its permits, enqueue re-admits that
context and commits a request before calling ActiveJob. An aborted surrounding
operation discards its callback. A queue exception leaves the committed request
available for recovery rather than clearing its pending flag.

The document retains one UUID, fixed start/end dates, retry budget, attempt count,
state and original context. Deliveries contain only the source, request UUID and
revision. Old contextless deliveries and date/retry overrides refuse before HTTP.
An eligible active request keeps its original owner and date window when another
sync asks to enqueue work; it cannot adopt that newer Sync.

## Claim, publish and recover

Claims take the real migration and credential session permits, then verify the
receipt under short publication locks. Each claim advances the revision. A stale
delivery cannot complete, defer, fail or clear a replacement attempt. HTTP occurs
outside the row transaction and uses only the retained remote ID and dates.

Snapshot staging and each financial publication repeat the request check inside
the [legacy publication boundary](provider-questrade-legacy-publication.md).
Staging captures the exact cache context before merging, so an intervening cache
write cannot be silently overwritten. Strict activity processing propagates row
failures; already committed rows replay through existing financial identities.
Successful completion commits the terminal receipt, cleared pending flag and
coverage marker together. The marker records the original request end, not the
time a delayed worker happened to finish. This preserves the next incremental
read's overlap even after a long interruption.

Valid empty responses and classified transient transport errors use the retained
retry budget. Exhausted valid empty polling can complete; exhausted unavailable
or malformed responses fail without a successful coverage marker. A successful
completion notification is separate from financial completion: notification
failure cannot turn a committed receipt into a failed request.

`SyncCleanerJob` invokes bounded due-request recovery. Recovery rechecks the
original context and redispatches the same request/revision, moving its dispatch
deadline forward. A crashed running attempt is reclaimable, and its next claim
advances the revision. Queue duplicates are harmless under this protocol; queue
uniqueness is not the ownership mechanism. The due column is a recovery deadline,
while the document's `resume_at` retains the request's not-before time.

Completed parents remain eligible for the existing delayed polling flow. When the
source can still be admitted, recovery retires an identified request with failed,
cancelled or missing ancestry or a changed account binding, without HTTP or a
financial progress update. Refused source admission cannot authorize cleanup;
remaining deletion/retirement lifecycle work must handle those cases. A new
admitted request receives a new UUID and records the replaced UUID. This account-
local receipt is current operational state, not an append-only request history.

## Historical jobs and table transfer

The generic stale-flag cleaner no longer clears Questrade flags. Operators must
drain old workers before explicitly disposing of an unidentified historical flag:

```sh
FAMILY_ID=<family-uuid> LEGACY_ACCOUNT_ID=<questrade-account-uuid> \
  bin/rails provider_data:dispose_questrade_activity_flag
```

This command scopes the source to the named family and writes a cancelled receipt
whose origin is `legacy_unowned` and disposition is `historical_owner_unknown`.
It does not invent a parent Sync, claim a successful fetch, clear cached data or
change financial history. It is not a way to cancel currently owned work.

Quiesced copying and migration preparation require settled activity work before
pausing legacy ownership. Unknown pending flags and active receipts block that
transition. The migration manifest retains the encrypted request as payload and
the revision, pending flag and recovery deadline as checkpoints, alongside the
existing activity cache and coverage marker.

Archives created before these columns existed cannot prove their values. Copy
verification compares the complete typed source projection and therefore rejects
such archives. Before financial identity evidence exists, use the explicit
supported recopy workflow. Once evidence exists, preserve that original proof
and require explicit reconciliation; never fill missing historical columns with
today's values or re-sign an old archive as though it captured them.

Full link creation/removal and retirement admission, native credential transfer,
unsupported/ambiguous activity identities and provider history acceptance remain
separate migration gates. These changes do not enable Questrade cutover.

The [request tests](../../test/models/questrade_account/activities_request_test.rb)
exercise actual dispatch, fixed windows, queue failure,
crashed attempts, stale delivery, parent cancellation, link changes, empty/error
polling, cache conflicts, completion notifications and refusal before quiescence.
The [copy tests](../../test/models/provider/account_data/questrade/activity_request_copy_test.rb)
exercise completed/disposed receipts, typed timestamps in shadow copies and
rejection of an authenticated historical archive missing the three new columns.
They require the new migration and a supported Rails/PostgreSQL test environment;
none has run in this workspace.
