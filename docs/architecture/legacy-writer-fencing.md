# Legacy writer fencing before cutover

The [LegacyWriterFence core](../../app/models/provider/account_data/legacy_writer_fence.rb)
and [Syncable#perform_sync dispatch](../../app/models/concerns/syncable.rb) now use
shared/exclusive session advisory locks and fresh ownership checks.
[LegacyWriterGuard](../../app/models/concerns/legacy_writer_guard.rb) adds explicit
guards to the public import/process methods across all 23 items. Up additionally
enforces its direct importer/processors, snapshots and provider-specific lifecycle
commands; see the [Up enforcement and remaining bypass audit](up-legacy-writer-fencing.md).
Focused tests are written but unexecuted. This is partial enforcement: the legacy integrations
still have the direct writers catalogued below. Scheduling ownership, a disabled
shared connection, and a successful shadow comparison do not drain those writers.
No migrations or runtime tests were executed for this work.

## Required boundary

The core exposes `Provider::AccountData::LegacyWriterFence.with_item(item, operation:)`,
`with_account(provider_account, operation:)`, `with_items(items, operation: :lifecycle)`
and `with_exclusive(item)`. Resolve account ownership using
the explicit item/account classes and foreign key in
[MigrationManifest](../../app/models/provider/account_data/migration_manifest.rb),
not `Account#provider`, which cannot identify one source on a multi-provider account.
Reject unknown source classes and mismatched families. Operations distinguish
`ingest`, `publish`, `lifecycle`, and `credentials` for auditing; they do not grant
different permissions to keep writing after cutover.

The exclusion key must exist before a migration-control row does. Derive a stable
PostgreSQL advisory key from a versioned namespace, legacy **base class name**, and
legacy item UUID. Use a deterministic digest with a documented integer encoding,
never Ruby `hash`, a token, or a control-row UUID. A hash collision may conservatively
serialize unrelated items; it must not grant access or change ownership checks.

Each admitted legacy operation holds a **shared session advisory lock** until all
its local writes, credential callbacks, and cleanup/rescue/ensure work finish.
Pin the database connection and release in `ensure`. Read the current control
state and reload the item **after** acquiring the lock. Admit a missing control
and explicitly legacy-owned states; deny `quiescing`, `active`, `rollback_pending`,
and `retired`. The current generic `failed` state is legacy-owned: a failure after
quiescing must retain its fenced state and record an error separately, rather than
reopen writes by switching to `failed`.

The future migration coordinator acquires the **exclusive session advisory lock** on the
same key. That proves every previously admitted operation has exited, including
operations that started before control-row creation. This lock can span HTTP in
legacy code without introducing a database transaction across HTTP. Do not use a
transaction advisory lock around only the final save: a request that fetched old
state before cutover could otherwise publish afterwards. Require acquisition
outside pre-existing row-lock transactions to prevent lock inversion. Reentrant
calls for the same item reuse the same permit/session; a child job reacquires its
own permit and cannot inherit permission from its serialized arguments. The core
uses nonblocking `pg_try_advisory_lock_shared`/`pg_try_advisory_lock`; a caller that
cannot acquire a permit receives `Busy`. Common `Sync#perform` marks rejected
dispatch stale, skips legacy post-sync repair and records a sanitized diagnostic;
it does not automatically retry the fence. Dispatch
constructs the syncer from the freshly loaded item, avoiding a pre-lock cached client.

Take advisory locks before control/connection/account row locks. Operations touching
several legacy items must declare the full set and lock it in a common order;
financial account locks then follow account UUID order. Rotating grants and Kraken
API keys also require their own shared legacy/native credential or nonce protocol.
An item fence alone cannot serialize duplicated credentials across several items.

The multi-item lifecycle API now acquires that complete set in type/UUID order,
rechecks every requested owner, and permits only subset reentry on the same
database session. Unknown acquisition/release outcomes discard the session.
These shared locks exclude migration drains, not concurrent legacy writers.
Aggregate operations must also lock and repeat their source inventory; see
[shared lifecycle admission](provider-shared-lifecycle.md). The multi-item tests
are written but have not run.

## Ordinary ingestion callgraph: every current provider

The common path is `SyncJob#perform → Sync#perform → Syncable#perform_sync →
Item::Syncer#perform_sync → item import method → Item::Importer#import`, followed
by `item.process_accounts → Account::Processor#process → resource/entry processors`.
Importers also persist discovery, raw snapshots and checkpoints. Protect both
import and publication; do not assume all financial changes happen in processors.

Each row below identifies the exact public import method. `process_accounts` is
the publication method on every listed item, with provider-specific arguments.
The import and processing methods are guarded on every row. Onchain and Sophtron
also validate their explicit account subsets inside the permit, before processing
any member. Except for the further Up-specific enforcement described above,
direct calls to the listed processor classes remain outside this item-method boundary.
The linked item class identifies its importer and account processor. All 23 have
their own `Item::Syncer#perform_sync` implementation.

| Legacy item | Import method | Account processor |
| --- | --- | --- |
| [AkahuItem](../../app/models/akahu_item.rb) | `import_latest_akahu_data` | `AkahuAccount::Processor#process` |
| [BinanceItem](../../app/models/binance_item.rb) | `import_latest_binance_data` | `BinanceAccount::Processor#process` |
| [BrexItem](../../app/models/brex_item.rb) | `import_latest_brex_data` | `BrexAccount::Processor#process` |
| [CoinbaseItem](../../app/models/coinbase_item.rb) | `import_latest_coinbase_data` | `CoinbaseAccount::Processor#process` |
| [CoinstatsItem](../../app/models/coinstats_item.rb) | `import_latest_coinstats_data` | `CoinstatsAccount::Processor#process` |
| [EnableBankingItem](../../app/models/enable_banking_item.rb) | `import_latest_enable_banking_data` | `EnableBankingAccount::Processor#process` |
| [IbkrItem](../../app/models/ibkr_item.rb) | `import_latest_ibkr_data` | `IbkrAccount::Processor#process` |
| [IndexaCapitalItem](../../app/models/indexa_capital_item.rb) | `import_latest_indexa_capital_data` | `IndexaCapitalAccount::Processor#process` |
| [KrakenItem](../../app/models/kraken_item.rb) | `import_latest_kraken_data` | `KrakenAccount::Processor#process` |
| [LunchflowItem](../../app/models/lunchflow_item.rb) | `import_latest_lunchflow_data` | `LunchflowAccount::Processor#process` |
| [MercuryItem](../../app/models/mercury_item.rb) | `import_latest_mercury_data` | `MercuryAccount::Processor#process` |
| [MonobankItem](../../app/models/monobank_item.rb) | `import_latest_monobank_data` | `MonobankAccount::Processor#process` |
| [OnchainWalletItem](../../app/models/onchain_wallet_item.rb) | `import_latest_onchain_data` | `OnchainWalletAccount::Processor#process` |
| [PlaidItem](../../app/models/plaid_item.rb), US and EU | `import_latest_plaid_data` | `PlaidAccount::Processor#process` |
| [QuestradeItem](../../app/models/questrade_item.rb) | `import_latest_questrade_data` | `QuestradeAccount::Processor#process` |
| [RedbarkItem](../../app/models/redbark_item.rb) | `import_latest_redbark_data` | `RedbarkAccount::Processor#process` |
| [SimplefinItem](../../app/models/simplefin_item.rb) | `import_latest_simplefin_data` | `SimplefinAccount::Processor#process` |
| [SnaptradeItem](../../app/models/snaptrade_item.rb) | `import_latest_snaptrade_data` | `SnaptradeAccount::Processor#process` |
| [SophtronItem](../../app/models/sophtron_item.rb) | `import_latest_sophtron_data` | `SophtronAccount::Processor#process` |
| [TradeRepublicItem](../../app/models/trade_republic_item.rb) | `import_latest_data` | `TradeRepublicAccount::Processor#process` |
| [Trading212Item](../../app/models/trading212_item.rb) | `import_latest_data` | `Trading212Account::Processor#process` |
| [UpItem](../../app/models/up_item.rb) | `import_latest_up_data` | `UpAccount::Processor#process` |
| [WiseItem](../../app/models/wise_item.rb) | `import_latest_wise_data` | `WiseAccount::Processor#process` |

Guard public importer and resource/entry-processor methods as well as the outer
sync operation. They are independently callable from jobs, controllers, tools and
tests. Use explicit declarations of methods/source resolvers, with reentrant
permits, rather than guessing ownership from processor class names at runtime.
Guard public `upsert_*` source-snapshot methods and lifecycle writes too: their
values are part of the final copied state even when they do not post entries.

The adopted items declare their import and processing methods explicitly through
the private `guard_legacy_writes` class method. The concern captures each original
`UnboundMethod` and prepends a wrapper once, preserving positional arguments,
keywords, blocks, return values and exceptions. Denial occurs outside the original
method's rescue/ensure clauses. A new permit reloads its receiver; admitted nested
calls reuse that receiver after rechecking persisted tenant and control ownership.
This retains SimpleFIN's current discovery evidence (`upstream_account_ids`) within
one sync, without importing stale caller transients into an independent operation.
The wrapper exposes neither an unguarded alias nor a bypass argument. Native
adapters remain independent of legacy imports and processors.

`scoped_accounts!` accepts arrays of persisted source accounts or relations for
the expected account class. It requires the admitted item receiver, reloads all
selected UUIDs through that item's trusted foreign key and rejects foreign,
deleted, reparented or cross-family-linked rows before any processor runs. It
preserves order and repeated IDs without adding other accounts. A loaded relation
retains its selected IDs and rechecks its predicates without reapplying limit or
offset; changed manual/visibility predicates reject the subset instead of silently
substituting another account. An unloaded relation evaluates after admission.
Sophtron's omitted keyword still evaluates its existing linked/visible default
on the fresh receiver. Concurrent source/link lifecycle changes still require
their own enforcement; a fresh subset alone is not a complete lifecycle fence.

`Account::ProviderImportAdapter` is not a sufficient enforcement point. Account
processors directly update balances, currency, accountables and valuation anchors;
resource processors directly delete entries/holdings and repair labels. Examples
include [Plaid account creation/linking](../../app/models/plaid_account/processor.rb),
[Plaid transaction removal](../../app/models/plaid_account/transactions/processor.rb),
[Monobank pending pruning](../../app/models/monobank_account/transactions/processor.rb),
[Binance holding deletion](../../app/models/binance_account/holdings_processor.rb),
and [Trade Republic stale cash-entry removal](../../app/models/trade_republic_account/activities_processor.rb).
The [SimpleFIN importer](../../app/models/simplefin_item/importer.rb) itself
reconciles/excludes pending entries, invokes the credit processor, updates linked
cash balances and schedules holdings application during account import.

## Entrypoints outside the ordinary sync tree

| Entrypoint | Writes or follow-on work requiring the item fence |
| --- | --- |
| [SimplefinHoldingsApplyJob#perform](../../app/jobs/simplefin_holdings_apply_job.rb) | Calls `SimplefinAccount::Investments::HoldingsProcessor#process` directly. |
| [SimplefinItem::BalancesOnlyJob#perform](../../app/jobs/simplefin_item/balances_only_job.rb) | Calls `SimplefinItem::Importer#import_balances_only`; discovery/snapshot writes are independently queued. |
| [QuestradeActivitiesFetchJob#perform](../../app/jobs/questrade_activities_fetch_job.rb) | Fetches, merges snapshots, calls `ActivitiesProcessor#process`, writes completion/pending flags; retries are not `Sync` children. |
| [SnaptradeActivitiesFetchJob#perform](../../app/jobs/snaptrade_activities_fetch_job.rb) | Fetches and merges snapshots, invokes `ActivitiesProcessor#process`, clears flags and updates a prior sync's statistics. |
| [SophtronRefreshPollJob#perform](../../app/jobs/sophtron_refresh_poll_job.rb) | Updates remote-job state; `import_transactions!` calls `Importer#import_transactions_after_refresh` and `SophtronAccount::Processor#process`. |
| [TradeRepublicRepairJob#perform](../../app/jobs/trade_republic_repair_job.rb) | Reprocesses cached account, activity and holding data without fetching or creating an item sync. |
| [Account::Syncer#apply_provider_balance_overrides](../../app/models/account/syncer.rb) | Resolves the retained legacy `IbkrAccount` link and calls [HistoricalBalancesSync#sync!](../../app/models/ibkr_account/historical_balances_sync.rb), which directly `upsert_all`s balances. Item scheduling filters do not stop this. |
| [DestroyJob#perform](../../app/jobs/destroy_job.rb) | Calls `model.destroy`, including provider cascades and remote revocation callbacks. Failure cleanup also updates the legacy deletion flag. |

`Sync#finalize_if_all_children_finalized` invokes `perform_post_sync` inside a Sync
transaction and row lock, including after a failed main phase. Consequently the
dispatch/item-method fences do **not** cover post-sync. An existing
exception to the other 22 empty item post hooks is
[OnchainWalletItem::Syncer#perform_post_sync](../../app/models/onchain_wallet_item/syncer.rb):
it calls `OnchainWalletAccount::Processor#repair_display_only_movements`, which
repairs labels and converts excluded Transaction entries into Trades using stored
security prices. Despite its database-only comment, `upgrade_to_trade →
exact_price_on → convert` can call
[ExchangeRate.find_or_fetch_rate](../../app/models/exchange_rate/provided.rb),
which fetches and caches FX when no stored rate exists. This needs a separate
fenced repair job or pre-captured FX plus a permit acquired before the finalizer
transaction; a late lock under the Sync row lock is unsafe. Preserve its position
after account materialization rather than moving repair into initial ingestion. Account
materialization and family transfer/rule work also require explicit ordering, but
must not be globally disabled as if they belonged exclusively to one provider.

Controller bypasses also exist. `link_existing_account`/`complete_account_setup`
invoke processors in [IBKR](../../app/controllers/ibkr_items_controller.rb),
[Trading212](../../app/controllers/trading212_items_controller.rb) and
[Trade Republic](../../app/controllers/trade_republic_items_controller.rb).
[Kraken#complete_account_setup](../../app/controllers/kraken_items_controller.rb)
invokes its processor; [Binance](../../app/controllers/binance_items_controller.rb)
and [Coinbase](../../app/controllers/coinbase_items_controller.rb) invoke holdings
processors while linking. [Sophtron](../../app/controllers/sophtron_items_controller.rb)
manual refresh/MFA completion calls `complete_manual_sync! →
import_transactions_after_refresh → process_manual_sync_account!` directly.
[Redbark](../../app/controllers/redbark_items_controller.rb) now reaches its guarded
import method during discovery. Account setup in other controllers still creates links,
accounts, ignored flags and cached source rows: for example,
[Up#fetch_up_accounts_from_api](../../app/controllers/up_items_controller.rb)
fetches and upserts outside `UpItem::Importer`.

The next concrete Sophtron boundary is the complete
`SophtronRefreshPollJob#perform` operation, before client construction, remote-job
reads, job-snapshot updates and the job's error cleanup. Its transaction importer
and account processor must also guard direct calls. Manual/MFA completion still
passes a client constructed earlier into `complete_manual_sync!`; guarding only
that late helper would retain stale credentials. Move client construction inside
an admitted, authorized item operation and verify the account/job association
before importing, processing, clearing job flags or scheduling child syncs.

For Onchain, guard `Importer#import` and `import_wallet`, the processor's `process`
and later `repair_display_only_movements`, and
[WalletLinker#link/#revise](../../app/models/onchain_wallet_item/wallet_linker.rb).
The linker deletes orphan/unselected source rows, creates financial accounts and
links, and schedules syncs. Also cover controller update/disconnect/destroy paths.
Keep the read-only `Importer#fetch_snapshot` preview usable with an unsaved item:
it is intentionally called before creating a persistent wallet connection.

Wrap the complete authorized controller operation before its first mutation or
provider request, retaining existing `Current.family` and administrator checks.
Do not acquire a blocking advisory lock from a late Active Record callback after
already taking link/account locks. A denied operation must not run its original
rescue/ensure code and clear flags on the now-native legacy row. Existing broad
rescues can also turn fence exceptions into apparent success; translate denial
at the outer job/controller boundary to an explicit skipped/superseded result.

Operator paths require the same permits: `simplefin_backfill.rake` calls
`SimplefinEntry::Processor#process` and destroys entries; holdings backfill queues
the apply job; pending cleanup/restore directly destroys or updates `Entry` rows;
prune-pending rewrites cached transactions; unlink/dev cleanup changes links and
destroys sources. See [the backfill](../../lib/tasks/simplefin_backfill.rake),
[pending tools](../../lib/tasks/simplefin_pending_cleanup.rake),
[snapshot pruning](../../lib/tasks/simplefin_prune_pending.rake), and
[unlink](../../lib/tasks/simplefin_unlink.rake). Encryption backfills and provider
settings migrations mutate copied credentials/settings too. Raw SQL, console
`update_columns` and unrestricted maintenance tasks are trusted bypasses, not
protected by Rails callbacks; prohibit their use on quiescing/native-owned legacy
sources or explicitly route them through the fence.

## Credentials, lifecycle and Plaid's shared grant

Financial publication and credential ownership need separate audits but the same
cutover exclusion. A read-only bank API call may rotate tokens or cookies; a
cleanup callback may revoke the grant still used by the native connection.

* [QuestradeItem::Provided](../../app/models/questrade_item/provided.rb) wraps
  refresh exchange in an item row lock and persists through `on_token_refresh`.
  [SnapTrade's refresh](../../app/models/provider/snaptrade.rb) also uses an item
  row lock and `apply_oauth_tokens!`. Those locks do not coordinate with the new
  `CredentialStore` or survive a consumed token whose response was lost. All
  consumers must join one durable refresh protocol before activation.
* Enable Banking `start_authorization`, `complete_authorization`,
  `reconcile_session_expiry!`, `revoke_session` and session-account discovery
  mutate independent consent/account membership. Fence the owning item and carry
  final consent changes into the authorization copy.
* Trade Republic login/QR/poll/update actions and `Importer#import` persist session
  blobs and pending login state. Ordinary cookie changes are not proof of a
  single-use exchange. [KrakenItem#next_nonce!](../../app/models/kraken_item.rb)
  needs the same-key legacy/native nonce handoff, not merely an item row lock.
* [SimplefinConnectionUpdateJob](../../app/jobs/simplefin_connection_update_job.rb)
  replaces the access URL; [SnaptradeConnectionCleanupJob](../../app/jobs/snaptrade_connection_cleanup_job.rb)
  can delete a remote authorization after a local account was destroyed. Item
  unlinking also detaches holding links. Retirement must not accidentally invoke
  callbacks that revoke a native-owned grant.

For Plaid, use the **same `PlaidItem` UUID fence for US and EU** and verify the
captured region/environment. The schema makes `plaid_id` unique; region-specific
application clients are not independent item grants. The complete consumer set is:

1. `PlaidItem::Importer` and [AccountsSnapshot](../../app/models/plaid_item/accounts_snapshot.rb):
   item/accounts/transactions/investments/liabilities reads, raw snapshots and
   `next_cursor` writes. The snapshot lazily fetches inside the import transaction;
   adding a fence must not widen that transaction or treat cursor copy as ledger acceptance.
2. [PlaidTransactionsRefreshJob](../../app/jobs/plaid_transactions_refresh_job.rb)
   calls `refresh_transactions(access_token)`;
   [PlaidTransactionsRefreshPollJob](../../app/jobs/plaid_transactions_refresh_poll_job.rb)
   calls `get_transactions(access_token, next_cursor:)` and schedules a follow-up.
   Polling does not itself save the cursor or post financial entries.
3. `PlaidItem#get_update_link_token` and `Family#get_link_token(access_token:)`
   use the existing grant. `Family#create_plaid_item!` exchanges a new public
   token: reserve its item identity before grant work and handle duplicate upstream
   items; do not silently attach an existing native-owned grant as a new legacy row.
4. `PlaidItem#remove_plaid_item` is a `before_destroy` remote removal callback.
   `data_migration:eu_plaid_webhooks` directly calls the SDK's
   `item_webhook_update` with each item's token, bypassing the usual importer.
5. [WebhooksController](../../app/controllers/webhooks_controller.rb) verifies
   signatures using a regional application client, then
   [WebhookProcessor#process](../../app/models/plaid_item/webhook_processor.rb)
   either schedules a sync or writes `requires_update`. Verification itself is not
   an item-token consumer. Resolve the authenticated item's current owner before
   scheduling/status changes; preserve events during quiescence for native replay.
   `PlaidFollowUpSyncJob`, refresh follow-up/all jobs and `SnaptradeFollowUpSyncJob`
   must check ownership when executed, regardless of who enqueued them.

Fencing `plaid_provider` construction is insufficient: it returns a cached regional
client and the request occurs later. Fence the whole item-bound operation. New
native calls must use the accepted credential/grant revision; old cached clients,
webhook status updates and delayed removal jobs cannot retain authorization to act.

## Drain, final copy and first enforcement slice

1. Deploy enforcement to **every** web/worker/operator process first. Drain or
   replace older process versions; their unfenced in-flight work is invisible to
   advisory locks. A quiet `Sync` table is not evidence that such work has exited.
2. Under the exclusive legacy advisory lock, validate family/item ownership,
   create/reload the control and commit `quiescing` with the shared connection
   disabled. Existing admitted operations have now drained; subsequently queued
   jobs acquire the shared lock, reread state and decline work. Preserve/replay
   incoming events rather than losing them to a successful HTTP acknowledgement.
3. Retain quiescing across bounded final-copy jobs. The internal
   [quiesced copy path](provider-quiesced-copy.md) now does this with an actual
   exclusive permit, while ordinary shadow copying cannot reclaim that state.
   Verify credentials, cursors, snapshots, auxiliary tables, links and financial
   evidence after draining. Once permanent identity evidence exists, use the
   retained-copy reader; do not replace its original archive or copy run. The
   combined durable coordinator remains unfinished. Complete or explicitly supersede pending
   auxiliary fetches and provider-specific account-child work, especially IBKR.
4. Under the exclusive fence, accepted grant protocol and short ordered row-lock
   transaction, verify the final copy/epoch and atomically activate native ownership.
   A timeout, crash or failed parity leaves quiescing/disabled, never both writers
   enabled. Rollback first drains native leases/credential sessions, transfers the
   latest state back and verifies it, then restores legacy ownership explicitly.

Common dispatch and the adopted item-method guards are present. The dedicated
[Up boundary](up-legacy-writer-fencing.md) now covers its direct importer,
processors, snapshot writers and provider-specific lifecycle commands. The
[Sophtron boundary](sophtron-legacy-refresh-fencing.md) also covers polling,
ingestion, discovery and its settings operations. These implementations have unrun
tests. [Legacy account unlink and Family destruction](provider-shared-lifecycle.md)
now have multi-item admission and pre-callback inventory checks. Other generic
account/link operations, remaining provider-specific direct
consumers, deployment drain and coordinated cutover still need completion; a
sync-only fence cannot establish readiness for any provider.

`DestroyJob` now acquires a lifecycle permit for every recognized legacy item or
account before destruction and retains it through ordinary failure recovery. The
job uses the fresh admitted receiver for both operations. A failed model-specific
destroy can no longer release its permit before resetting `scheduled_for_deletion`.
Busy, ownership-changed and invalid-source failures propagate without changing
that flag. Family destruction now enters its own aggregate boundary through
`Family#destroy`, including when invoked by this job. A financial Account destruction
graph can also affect transfer counterparties and retained evidence; that admission
and its scheduling/recovery paths remain unfinished.

Required acceptance tests: migration begins before a control exists while an old
writer holds its permit; old HTTP completes after quiescence was requested;
blocked retries do not clear flags or write snapshots; direct processor and
controller calls cannot bypass ownership; exceptions/process termination release
session locks; connection-pool reuse leaks no permit; two items do not block one
another; parent/leaf reentry does not deadlock; delayed jobs and IBKR overrides
remain blocked after activation; final-copy failures remain fenced; and token
rotation/revocation and webhook arrival interleave safely with cutover/rollback.
The [core/dispatch tests](../../test/models/provider/account_data/legacy_writer_fence_test.rb)
cover state admission, before-control exclusion, real competing database sessions,
reentry, exception cleanup, family identity, fresh dispatch, direct Up calls and
SimpleFIN proof lifetime. They disable fixture transactions: entry inside an
existing transaction is rejected without a runtime test bypass. The
[guard tests](../../test/models/concerns/legacy_writer_guard_test.rb) exercise
forwarding, denial before rescue/ensure, declaration safety and all 46 adopted
entrypoints. The [subset tests](../../test/models/provider/account_data/legacy_account_scope_test.rb)
cover both providers' stale/foreign/deleted selections, source reparenting,
limited relation filters, default visibility, input types and ownership denial.
Five existing Akahu/SimpleFIN processor-behavior cases now expect and
mock their exact item-fence boundary, preserving fixture isolation while their
original financial/error assertions run. Other direct `Item::Syncer` tests do not
cover the outer dispatch boundary, even when a guarded item method is called
inside them. Remaining checks above are proposed; none are executed acceptance evidence.
