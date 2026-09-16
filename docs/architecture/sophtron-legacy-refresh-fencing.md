# Sophtron delayed refresh ownership

Status: implementation and behavioral tests written; no tests, migrations or
cutovers executed. This closes named legacy entrypoints, not the full Sophtron
migration. See [implementation status](provider-implementation-status.md).

`SophtronRefreshPollJob` now acquires the shared legacy item permit before client
construction. It refreshes the selected source account from that admitted item,
rejects cross-family financial links, and checks an optional Sync's original owner.
The permit covers polling, status/error writes, transaction import/processing and
follow-up scheduling. A retry must reacquire it; serialized job arguments are not
authority to act after migration ownership changes. Error handlers execute inside
admission and cannot turn an ownership rejection into a legacy status write.

`LegacyWriterFence.scoped_sync!` requires the exact admitted item and a persisted,
current Sync. It rejects foreign/deleted runs, cancellation, failed/stale runs and
invalid ancestry. Ancestor traversal is bounded and detects cycles. Sophtron opts
in to completed runs because its existing item sync can finalize before a delayed
refresh returns. This preserves that legacy scheduling behavior without treating
failed or cancelled work as usable. Polling rechecks context after HTTP and before
financial processing. This is cooperative cancellation; cancellation arriving
after a check does not atomically retract an already started write.

`SophtronInitialLoadJob` holds the same permit while checking pending work and
scheduling another wait or sync. `SophtronItemsController` acquires it around the
entire `sync`, `connection_status` and `submit_mfa` action, after family lookup and
admin authorization. The admitted fresh item constructs the client. Denied HTML
requests return to accounts with a localized message; JSON callers receive a
conflict. A support diagnostic contains item/family context, without the MFA input,
credentials, upstream job payload or exception message.

`DestroyJob` now rethrows ownership/busy errors before its general failure handler
can reset `scheduled_for_deletion`. Sophtron's item/account destroy methods now
acquire their own permits before Active Record begins destruction. The generic
job also retains admission for recognized legacy items/accounts through ordinary
failure recovery, so its deletion-flag reset remains inside the permit. These
paths and their tests are written, not runtime-verified.

## Verification authored

- [Job enforcement](../../test/jobs/sophtron_legacy_jobs_test.rb): quiescing/native
  rejection, fresh client credentials, a competing exclusive drain during HTTP,
  foreign/cancelled Syncs, cancellation during HTTP, initial-load scheduling and a
  cross-family financial link. These cases run without fixture transactions.
- [Sync scope](../../test/models/provider/account_data/legacy_sync_scope_test.rb):
  admission, exact ownership, stale/deleted/foreign contexts, completed-run opt-in,
  ancestor cancellation and cycle rejection.
- Existing polling and controller tests substitute their session permit while
  retaining transaction fixtures and current source/account/Sync validation;
  controller rejection cases assert no HTTP, state writes or scheduling on
  rejection. [DestroyJob tests](../../test/jobs/destroy_job_test.rb) assert that
  refused deletion preserves lifecycle flags and the original exception.

## Remaining Sophtron acceptance

The named public ingestion, scheduling, credential, discovery and lifecycle
operations below are now covered in code. This is not blanket enforcement for
every caller that can write the legacy tables.
The controller's manual refresh state machine still needs durable job-to-account
and job-to-Sync binding, explicit cancellation handling, and protection against
stale/repeated MFA responses. Generic account/link operations must participate in
the same boundary; a shared migration permit alone does not serialize concurrent
legacy relinking or credential replacement.

The native refresh/MFA state machine, immutable request/response handoff, pending
account-child work at cutover and native manual-sync policy remain gates. A legacy
poll cannot simply be resumed as a native job: transfer and verify its exact
account/job/grant context under quiescence or explicitly supersede it. No native
activation is authorized by the presence of these wrappers or unrun tests.

## Public ingestion and scheduling entrypoints

`SophtronItem::LegacyAccess` now admits direct importer, account processor,
transaction collection and single-entry processor calls. Admission refreshes the
exact selected source account and its financial link before normalization or
merchant creation. A stale account argument cannot follow a new parent item;
foreign-item selections and cross-family financial links are rejected. A new
account snapshot is created under the admitted persisted item and uses its current
institution/manual-sync settings. Persisted snapshots cannot change the remote
account identifier.

`Importer` no longer accepts a prebuilt `sophtron_provider:` client. It constructs
its client from the admitted item on first use. Polling and manual-refresh callers
were updated; client construction has no HTTP side effect, and no request is
duplicated. Each request validates its optional Sync and selected account before
and after HTTP, including error responses, before response normalization and
snapshot/status publication. Ownership and scope errors escape the legacy
best-effort rescue loops instead of becoming partial-success counters.

Item/account snapshot writers, `schedule_account_syncs`, `start_initial_load_later`
and direct `SophtronItem::Syncer#perform_sync` participate in the permit. Scheduling
reloads only the selected accounts, preserving loaded relation IDs, filters and
requested windows; it validates the parent Sync before each account enqueue.
Processors propagate a supplied Sync to each transaction. Ordinary import,
processing, scheduling and Syncer calls reject completed Syncs. The delayed
`import_transactions_after_refresh` path and its explicitly opted-in poll
processing/scheduling retain completed-Sync support, with cancellation and ancestry
checks still applied.

The permit is a session lock, acquired before ordinary write transactions and held
through requests, processing and scheduling. It does not add an HTTP-spanning row
transaction. Cooperative checks do not serialize concurrent legacy credential
edits or relinking, or retract a financial write already started before cancellation.

Fourteen additional nontransactional cases in
[`SophtronItem::LegacyAccessTest`](../../test/models/sophtron_item/legacy_access_test.rb)
exercise these boundaries, including actual competing-session drain exclusion.
Existing Sophtron fixture tests use a named
[`SophtronFixtureFenceHelper`](../../test/support/sophtron_fixture_fence_helper.rb)
to substitute the session permit while retaining fresh-source, account and Sync
validation. That helper depends on the fence context format and is not evidence
that a real permit was acquired. Those tests and the new real-commit cases must
both pass in a configured migration-created test database; none were executed in
this environment.

## Credential verification and discovery

`SophtronItem#ensure_customer!` and `verify_and_provision_customer` now acquire
credential admission before checking persisted customer state or constructing a
client. The first method no longer accepts a prebuilt `provider:` argument. The
verification command retains the existing health check, customer reuse, missing
customer creation, and relist fallback for empty create responses. Its client is
created once inside admission and reused through that command. API failure still
marks the item as requiring an update and exposes the existing connection-error
message; the support diagnostic contains only item/family and error-class context.
Ownership denial cannot execute that error handler.

`fetch_remote_accounts`, `search_institutions`,
`persist_remote_sophtron_accounts` and `upsert_sophtron_account` now admit their
fresh item before cache lookup, HTTP, normalization or snapshot persistence. The
discovery cache uses a keyed fingerprint of credentials, endpoint, customer and
institution together with the family/item identity. Changing credentials cannot
reuse a response captured for the prior credentials, and raw credentials never
appear in cache keys. Existing five-minute expiration and force-refresh behavior
are retained; older cache keys are abandoned and expire normally.

The controller's `update` action now holds credential admission before persisting
settings and through verification/rendering. `preload_accounts`, `select_accounts`,
`select_existing_account` and `setup_accounts` retain their selected fresh item for
the whole discovery action. Institution search delegates to the fenced model
method. Their general error handlers propagate ownership errors to the common
sanitized denial handler. Existing family lookup, admin restrictions, strong
parameters, success/error rendering and redirect behavior remain in place. Creating
a new item still starts with its initial insert; subsequent verification admits the
new persisted identity.

Nine nontransactional cases in
[`SophtronItem::DiscoveryTest`](../../test/models/sophtron_item/discovery_test.rb)
cover denied cached/direct paths, fresh credential/institution state, actual
competing-session exclusion throughout HTTP, customer fallback and status handling,
credential-sensitive caching and discovery persistence. Five controller cases cover
denied updates/discovery, updated credentials, validation rendering and the existing
admin boundary. All are authored and unrun.

This is migration ownership fencing, not a credential-rotation protocol. The shared
permit does not serialize two permitted legacy operations against one another.
Concurrent credential replacement, duplicated credentials on a newly created item,
and source-specific consent/customer handover still require cutover policy. The
raw `sophtron_provider`/`Provider::SophtronAdapter.build_provider` client factories
are not full-operation admission boundaries; the latter currently has no direct
Sophtron caller in the repository. New-institution credential cloning/remote
creation and the account lifecycle now use the commands below. Direct Active
Record credential writes and maintenance scripts must use a coordinated boundary
rather than relying on named commands to intercept every database mutation.

## Link, institution and deletion operation boundaries

`SophtronItem::Lifecycle` now owns new/existing account linking, account setup,
institution connection, manual-mode selection and disconnect. The corresponding
controller actions retain their existing admin and family checks, then acquire a
whole-action permit before discovery, remote mutation or financial writes. The
public commands also acquire admission when invoked without a controller. They
reject items scheduled for deletion before new linking, institution requests or
manual-mode changes. No permit is acquired by extending another item's lock set.

All three account pickers now submit a signed, purpose-bound grant with a
15-minute lifetime. Its client-visible claims contain only item/family IDs, an
existing financial Account ID when applicable, a fixed flow name and an opaque
fingerprint. Credentials, customer/institution identifiers and upstream responses
are not present. The fingerprint incorporates the keyed discovery identity and
institution/job/deletion state. Existing parameter filtering hides the token in
request logs. New/existing link POSTs resolve the token's exact family-scoped item
and never fall back to the family's currently configured connection. Setup also
checks that the signed item matches its route. Signature, expiry, family, flow,
financial account and current fingerprint are checked before discovery or writes.
The retained admitted receiver must match the freshly loaded state too.

`render_selection_form` issues these grants for initial account selection and
the successful connection/post-MFA completion paths. Setup issues its own flow.
Missing or stale grants return the existing localized connection-unavailable
response and require reopening the picker. These grants bind the displayed
connection; they do not add consent, replace admin/CSRF checks, or serialize later
credential changes during an already admitted request.

Existing-account linking looks up the selected financial account in the admitted
family before any HTTP. After discovery it locks that Account, then the exact
Sophtron source, and checks both links again before creating `AccountProvider`.
New-account setup locks source rows in a stable order and creates only accounts
belonging to the admitted item/family. The existing zero-balance behavior in the
account picker, snapshot balance/subtype behavior in setup, skipped selections
and initial-load scheduling are retained. The permit remains held through that
scheduling; HTTP is outside row transactions. These checks do not retrofit locks
into arbitrary generic account/link writers.

Additional-institution connection now makes its remote request under the original
item's permit, using its admitted credentials/customer. A short transaction after
HTTP locks and rechecks the original item's family, credentials, endpoint,
customer, institution, job and deletion state before saving the result. The clone
is not persisted until a valid response supplies both institution and job IDs.
Failed/incomplete requests therefore leave no empty local clone. Existing source
and financial account IDs remain unchanged. An external success followed by a
local rejection/crash still needs provider-specific reconciliation; this is not a
durable or idempotent remote-provisioning workflow. Credential/customer consent
lineage shared by cloned items also remains a cutover prerequisite.

`unlink_all!`, `unlink_account!`, `destroy_later`, and direct item/account `destroy`
now enter the same lifecycle permit. Unlinking preselects each source's financial
Account lock set, locks those Accounts in order, then locks the selected source
and its links. Changed/reparented links or foreign-family financial accounts are
rejected without extending the lock set. Holdings are detached and retain their
IDs and financial accounts. Preview performs no mutations; a repeated unlink is
idempotent. Ordinary per-source failures retain a sanitized result and prevent
disconnect from scheduling deletion. Ownership failures propagate. Diagnostics
contain only item/source IDs and error classes and cannot replace the original
unlink error result. Direct destruction fails if unlinking fails.
Direct source destruction retains its Account/source locks through removal.
Dependent destruction rejects a link that reappeared after the parent detached
its accounts, rather than taking new financial locks after earlier source locks.

Sixteen nontransactional cases in
[`SophtronItem::LifecycleTest`](../../test/models/sophtron_item/lifecycle_test.rb)
exercise real competing-session exclusion across requests and scheduling,
ownership denial, link races/tenancy, setup balance/subtypes, clone success/failure
and stale credentials/customer/institution state, dry-run/idempotent unlink,
holding preservation, failure handling and direct deletion. Six cases in
[`SophtronItem::SelectionTest`](../../test/models/sophtron_item/selection_test.rb)
cover grant contents, expiry, tampering, scope and current/retained source state.
Eight added controller cases cover lifecycle denial, admin/family boundaries,
missing/tampered/expired/stale/foreign grants and token issuance in every picker
render path. Existing connection/link/manual-mode cases continue to exercise
their response behavior. All tests are authored and unrun.

Concrete remaining lifecycle gates:

- Generic `Account`, `AccountProvider`, family destruction and maintenance calls
  must enter a coordinated source boundary before their write transaction.
  Direct `delete`/`delete_all` bypass model destruction. An unfenced transaction
  calling Sophtron destruction now fails closed rather than obtaining its permit
  after taking financial locks.
- A shared migration permit excludes migration, but permits concurrent legacy
  operations. The named link commands take row locks; raw link/holding writes,
  concurrent credential changes, remote provisioning retries and in-flight
  lifecycle commands around deletion still require a complete serialization and
  reconciliation policy. The post-request institution identity check rejects a
  stale local publication but cannot undo the upstream request.
- Existing delayed refresh/MFA/job ownership, native manual-mode policy and exact
  account-child handover remain unverified cutover prerequisites. No writer was
  activated and no legacy table or attachment was removed by this slice.
