# Legacy provider row retirement inventory

This is a source-code inventory for a callback-free retirement command, not an
activation or deletion authorization. It covers the 23 providers in
[MigrationManifest](../../app/models/provider/account_data/migration_manifest.rb)
and the schema plus authored migrations available on 2026-09-16. The schema file
predates the new ingestion migrations; both were inspected. Runtime tests and
migrations remain unrun in this environment.

The command currently declares reviewed removal dispositions for Up, Mercury,
Brex and [Akahu](akahu-native-lifecycle.md). This declaration preserves each
adapter's readiness and cutover gates; it does not establish runtime acceptance.

## Common disposition

Every legacy item has dependent provider accounts. Every legacy provider account
has a dependent polymorphic `AccountProvider`. Every item includes
[Syncable](../../app/models/concerns/syncable.rb), whose dependent destruction
removes original Syncs; [Sync](../../app/models/sync.rb) also destroys children
and successors. Ordinary `destroy`, `destroy_all`, `destroy_later` and
[DestroyJob](../../app/jobs/destroy_job.rb) are not retirement operations.

The command must enumerate and lock the exact item/account inventory, validate
the accepted native cutover and all retained owners, then remove only the
reviewed compatibility rows. All account-to-item foreign keys are restrictive
except **Wise**, whose database FK cascades account deletion when its item is
deleted. Delete verified children first and check the inventory even for Wise;
its cascade must not dispose of an unexamined account. See
[schema foreign keys](../../db/schema.rb) and
[Wise's original migration](../../db/migrate/20260618120000_create_wise_items_and_accounts.rb).

Keep financial Accounts, Entries, Transactions, Trades, Holdings and their user
protections unchanged. Keep the original `AccountProvider` UUID and its dual
legacy/shared fields. Its polymorphic legacy columns have no FK to the source,
and [policy retention](../../db/migrate/20260916000700_retain_account_source_policies.rb)
deliberately makes those original fields immutable once policy history exists.
Removing the AP instead would nullify Holding associations and may invoke
CoinStats/Onchain tracking-row callbacks; see
[AccountProvider](../../app/models/account_provider.rb).

The only additional incoming financial-account FKs found are
`accounts.plaid_account_id` and `accounts.simplefin_account_id`. They block raw
source deletion. Clearing either needs an explicit disposition under financial
account locks proving the same original source and shared replacement; ordinary
`dependent: :nullify` callbacks are not that proof. No such extra direct FK was
found for the other 21 providers. Polymorphic AP and Sync references remain
historical scalars rather than becoming references to different UUIDs.

Twenty item models declare a logo attachment; their account models declare no
attachments. Onchain Wallet, Trade Republic and Wise declare none. No non-logo
attachment was found on these legacy source models. This is a reviewed allowlist,
not permission to ignore unexpected attachment rows: reject extra names/types or
new associations until reviewed. [AuxiliaryCopier](../../app/models/provider/account_data/auxiliary_copier.rb)
records explicit absence or verified bytes and creates a shared-connection
attachment to the same blob. Retirement must preserve that blob, target
attachment, variants and original encrypted auxiliary evidence. Remove only the
exact old attachment row without purging storage, after verifying its captured
header and target. IBKR retains its
[original auxiliary format](../../app/models/provider/account_data/ibkr/auxiliary_copier.rb).
Financial transaction/document attachments are outside this deletion inventory.

## Per-provider additions

All rows below also require the common disposition. “No additional child found”
means no separate model association/job was found in this audit, not that the
provider's native parity or cutover is accepted. The exact copied columns are
listed in [MigrationManifestCatalog](../../app/models/provider/account_data/migration_manifest_catalog.rb).

| Provider | Attachment | Additional disposition before removing its accounts/item |
| --- | --- | --- |
| [Akahu](../../app/models/akahu_item.rb) | Logo | No additional child found. Preserve account IDs, configured start dates and complete original transaction payloads. |
| [Binance](../../app/models/binance_item.rb) | Logo | Preserve combined-account identity, raw assets/history and signed history bootstrap receipts; cached candidate history is not proof of coverage. No separate deferred job found. |
| [Brex](../../app/models/brex_item.rb) | Logo | No additional child found. Preserve token/base URL provenance and account kind, transaction identity and per-account initial history disposition from the pilot cutover. |
| [Coinbase](../../app/models/coinbase_item.rb) | Logo | No additional child found. Preserve original activity/trade identities and accepted cache observations; row retirement must not recreate financial trades. |
| [CoinStats](../../app/models/coinstats_item.rb) | Logo | AP destruction itself deletes the tracking row. Retain the AP and exact original account/wallet identity; do not invoke that unlink callback. |
| [Enable Banking](../../app/models/enable_banking_item.rb) | Logo | Retain the migrated independent authorization, membership edges, session identity/expiry and captured consent fields. They are shared runtime rows, not disposable item children. No removal callback was found. |
| [IBKR](../../app/models/ibkr_item.rb) | Logo, original IBKR format | Retain report dates, cached cash/equity/holding/activity input, historical command batches, Account Sync handoffs and original logo receipts. Deleting the item must not remove the Sync ancestry needed by those inputs. |
| [Indexa Capital](../../app/models/indexa_capital_account.rb) | Logo | Explicitly settle `activities_fetch_pending`. Its [activities job](../../app/jobs/indexa_capital_activities_fetch_job.rb) only clears the flag because no activity endpoint exists. Account destruction enqueues [cleanup](../../app/jobs/indexa_capital_connection_cleanup_job.rb); the remote delete is currently a TODO, not implemented revocation. Preserve authorization IDs and cached holdings. |
| [Kraken](../../app/models/kraken_item.rb) | Logo | No additional child found. Preserve account type, assets and original transaction payloads. |
| [Lunch Flow](../../app/models/lunchflow_item.rb) | Logo | No additional child found. Preserve idless occurrence evidence, downstream account/institution IDs and pending transaction observations. |
| [Mercury](../../app/models/mercury_item.rb) | Logo | No additional child found. Preserve token/base URL provenance, liability/status normalization evidence and per-account pilot history disposition. |
| [Monobank](../../app/models/monobank_item.rb) | Logo | Preserve `history_synced_from`, `statement_synced_through` and raw held transactions used by retained history. Do not infer coverage from item synchronization timestamps. No separate deferred job found. |
| [Onchain Wallet](../../app/models/onchain_wallet_item.rb) | None | Preserve chain/address/contract/asset identity and the original source-UUID ingestion namespace. AP destruction deletes its tracking row; keep the AP. Captured RPC/FX evidence and configuration remain shared runtime input. |
| [Plaid](../../app/models/plaid_item.rb) | Logo | Resolve the direct Account FK. Bypass `remove_plaid_item`, which makes a real upstream removal call. Drain/admit the refresh, poll and follow-up job chain; preserve original cursor plus cached added/modified/removed observations and their acceptance dispositions. A cursor or refresh-cache flag alone is not financial acceptance. |
| [Questrade](../../app/models/questrade_account.rb) | Logo | Under the exclusive permit, require [ActivitiesRequest.assert_settled_for!](../../app/models/questrade_account/activities_request.rb): no pending flag or queued/running/retry-wait receipt. Retain the terminal encrypted request, revision, fixed dates and coverage in the archive. Require [usable original credential proof](../../app/models/provider/account_data/questrade/retained_credentials.rb); `requires_update` after uncertain exchange must not become a usable copied refresh token. |
| [Redbark](../../app/models/redbark_account.rb) | Logo | Account destruction enqueues [connection cleanup](../../app/jobs/redbark_connection_cleanup_job.rb), currently a local no-op rather than remote revocation. Bypass it and preserve original account identity/cache. |
| [SimpleFIN](../../app/models/simplefin_item.rb) | Logo | Resolve the direct Account FK. The item removal callback is currently a no-op. Block prepared/claiming/claimed [credential claims](../../app/models/provider_credential_claim.rb), retain terminal claim/result/cancellation history and original Sync ID, and dispose of signed deferred holdings requests explicitly. Preserve the copied liability sign hint and its expiry/absence. The balances-only job is separately queued and admitted. |
| [SnapTrade](../../app/models/snaptrade_item.rb) | Logo | Bypass actual [OAuth revocation](../../app/models/snaptrade_item/provided.rb) and account-triggered [remote connection deletion](../../app/jobs/snaptrade_connection_cleanup_job.rb). Settle activity pending flags and deferred activity/follow-up jobs; they can outlive the original Sync. Preserve OAuth grant, authorization IDs, expiry and original cached activity/holding evidence. |
| [Sophtron](../../app/models/sophtron_item.rb) | Logo | Resolve `current_job_id`, `current_job_sophtron_account_id`, `job_status` and pending/MFA response state explicitly. The account pointer is a scalar indexed UUID, not an incoming FK. Initial-load and refresh-poll jobs are separate admitted work; their parent Sync completing does not finish the remote job. Preserve raw job/customer data and exact account context. |
| [Trade Republic](../../app/models/trade_republic_item.rb) | None | Resolve pending login/session state and all timeline/positions cache dispositions. [RepairJob](../../app/jobs/trade_republic_repair_job.rb) invokes account processors separately from the ordinary Sync. Preserve mapped cash/portfolio IDs, original holding IDs, timeline receipt chains and dated quote evidence; deleting rows cannot complete those contracts. |
| [Trading 212](../../app/models/trading212_item.rb) | Logo | No additional child found. Preserve environment, instruments cache, order/position checkpoints and all raw transaction/order/dividend inputs with their original account identity. |
| [Up](../../app/models/up_item.rb) | Logo | No additional child found. Preserve explicit resource policy choices, original transaction identities, initial per-account history hints and the original pilot cutover Sync. |
| [Wise](../../app/models/wise_item.rb) | None | Account FK uses `ON DELETE CASCADE`: enumerate and delete only verified accounts before the item. Preserve profile/balance identities, retained statements, profile-wide fallback evidence and unresolved statement start boundaries. An empty account relation after the cascade would not prove a complete inventory. |

## Deferred work and credential boundaries

An empty `item.syncs.incomplete` relation is necessary but insufficient. For
example, [SnapTrade activity work](../../app/jobs/snaptrade_activities_fetch_job.rb)
can fetch and publish after its parent finishes, and Plaid's
[refresh](../../app/jobs/plaid_transactions_refresh_job.rb) /
[poll](../../app/jobs/plaid_transactions_refresh_poll_job.rb) path directly calls
the provider without joining the migration permit in those jobs. The generic
[legacy fence](../../app/models/provider/account_data/legacy_writer_fence.rb)
only excludes consumers that actually acquire it. These are provider eligibility
gates; do not extend a pilot retirement allowlist based solely on common table
shape.

[ApplicationJob](../../app/jobs/application_job.rb) discards missing GlobalID
arguments. That prevents some queued jobs from starting after physical removal;
it does not stop an already deserialized worker, prove its observations were
applied, or settle a consumed credential token. ID-based SimpleFIN jobs and
Questrade recovery also have their own admission rules. Do not replay old jobs
against a fabricated legacy object or silently redirect them to native work.

SimpleFIN's current credential gate blocks prepared/claiming/claimed rows;
uncertain is terminal retained ambiguity, not successful installation. Preserve
that distinction. Questrade's separate committed refusal state and terminal
activity request likewise must retain their original meaning after removal.

## Retained proof and post-removal replay

Capture [RetiredOwner](../../app/models/provider/account_data/retired_owner.rb)
witnesses for every item/account mapping while their rows still exist, with the
actual exclusive permit, exact family/control/connection, verified original copy
and native cutover receipt. The witness cannot be reconstructed from a later
shared account. The command must also account for live source rows without a
mapping, mappings without rows, and unexpected attachments. Witness capture only
visits known mappings and is not by itself a complete physical inventory check.

Retain all original versions of encrypted legacy snapshots and their HMAC
checksums, account reverse-index receipts, identity bootstrap evidence, auxiliary
archives/checkpoints, retained input proofs, policy revisions, SourceRecords,
EntrySource/HoldingSource rows, native generations/batches/checkpoints and
Account Sync inputs/preparations/selected pointers. Never rewrite an originally
unlinked archive's financial binding after later setup.

After removal, an idempotent retirement replay must start from the retained
control/mapping and its durable completion disposition. `RetiredOwner.prepare!`,
the legacy exclusive-fence entrypoint and live-copy verification all require the
original item; they cannot be the first step of an already-completed replay.
Instead authenticate the recorded item/account archives through `resolve!` and
compare the retained receipt, missing-row inventory and exact shared owners.
Missing rows without witnesses must fail closed; present contradictory rows
must not be replaced by an archive. Do not create a fake Active Record item to
obtain a permit.

The retained resolver currently also requires the original cutover Sync to exist
under the original native connection. Preserve that Sync and its ancestry.
[SourceOwners](../../app/models/ingestion/source_owners.rb), policy binding and
unlink use authenticated retired source proofs for financial ownership. The
[family history query](provider-retained-sync-history.md) uses the immutable
connection witness to expose original legacy Sync UUIDs and owner tuples after
removal; it performs no scheduling or archive decryption. A returned legacy
Sync's `syncable` association is nil, and history must not interpret that as a
new native owner.

Keep legacy model classes, manifest declarations and compatibility routing until
their remaining reflection, export, webhook, job and support consumers have
separate dispositions. Row retirement is distinct from dropping tables/classes,
remote disconnection, financial account destruction and full-family erase.
