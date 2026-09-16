# Up legacy writer enforcement

Up's source-bound importer, processors, snapshots and provider-specific lifecycle
commands now acquire the [legacy writer fence](legacy-writer-fencing.md).
These changes do not activate native Up, move data, run migrations, or establish
that every shared caller has been drained. Tests are authored but unexecuted;
the current environment does not provide Ruby.

## Enforced entrypoints

| Entry | Boundary and preserved behavior |
| --- | --- |
| `Syncable#perform_sync`, `UpItem::Syncer#perform_sync` | The whole Up sync has one permit, including setup flags, stats and account-child scheduling. Direct syncer calls also validate the fresh Sync owner, status and ancestors through `scoped_sync!`. |
| [`UpItem::Importer#import`](../../app/models/up_item/importer.rb) | Acquires admission before constructing a client from current credentials. The constructor now accepts only the item; callers cannot supply a client created before admission. Accounts, transaction fetches, snapshot storage and authentication-error state changes remain inside the permit. HTTP does not introduce a database transaction. |
| `UpItem#import_latest_up_data`, `process_accounts`, `schedule_account_syncs` | Explicit item method guards reload the receiver/query and retain the outer permit across nested commands. |
| [`UpAccount::Processor#process`](../../app/models/up_account/processor.rb), [`UpAccount::Transactions::Processor#process`](../../app/models/up_account/transactions/processor.rb), [`UpEntry::Processor#process`](../../app/models/up_entry/processor.rb) | Each direct entry reacquires admission and constructs a fresh processor from the persisted selected account. The account must still belong to the selected item and any financial link must belong to its family. Reusing a processor cannot reuse a cached financial account or import adapter. Balance updates, merchant creation, transaction enrichment and pending pruning run inside admission. A supplied category match is resolved against the current financial family's categories before assignment. |
| `UpItem#upsert_up_snapshot!`, `UpAccount#upsert_up_snapshot!`, `UpAccount#upsert_up_transactions_snapshot!` | Public snapshot saves are guarded. Existing source rows reload after admission; new discovery rows resolve by admitted item and external account ID. Saving a new account snapshot still leaves the caller persisted and reloadable. |
| [`UpItem::Lifecycle`](../../app/models/up_item/lifecycle.rb) | Discovery, settings/token updates, new-account linking, existing-account linking, setup/skip choices, and combined unlink-plus-deletion scheduling each have one permit before HTTP or an ordinary write transaction. Existing-account lookup uses the admitted item's family. Link operations reread provider links under row locks. Existing loan signs, depository subtypes, ignored flags, partial unlink results and deferred sync behavior are retained. |
| `UpItem#unlink_all!`, `destroy_later`, `destroy`; `UpAccount#destroy` | Direct calls and `DestroyJob` destruction cannot bypass admission. Destruction reloads the receiver before Active Record opens its transaction. Nested account destruction reuses its parent's permit. Existing ingestion/migration foreign keys and dependent-association restrictions remain intact. |

[`UpItemsController`](../../app/controllers/up_items_controller.rb) delegates source
writes to the lifecycle commands and retains its existing family lookup, admin
checks, strong parameters and return-path checks. A denied settings/link operation
redirects with the existing error copy and captures only source identity and error
class in `DebugLogEntry`. No raw error text, credentials or payload are logged by
that denial handler. The existing local-only raw Up debug guard is unchanged.

## Remaining shared bypasses and gates

The following are concrete limitations, not covered by the Up-specific wrappers:

- [`AccountsController#unlink`](../../app/controllers/accounts_controller.rb)
  detaches holdings and destroys `AccountProvider` links inside its own
  transaction. Up source rows deliberately survive, so `UpAccount#destroy` is
  never called. The controller must resolve the complete source set and acquire
  admission before the transaction; a late account-destroy callback is not enough.
- [`Account::Linkable`](../../app/models/account/linkable.rb) removes provider links
  during financial account destruction. Direct `AccountProvider#create!`,
  reassignment and destruction are also shared operations. They need a source-set
  lifecycle boundary that coordinates all affected legacy/native writers and
  financial-account locks. The Up picker commands cover their own uses only.
- [`Family`](../../app/models/family.rb) destruction cascades into legacy items
  after entering an outer transaction. Up destruction now rejects initial fence
  acquisition in that transaction. A family drain coordinator must acquire the
  complete source set in deterministic order before any cascading write. This
  fail-closed behavior is an explicit rollout prerequisite; family deletion has
  not been made operational for this path by this slice.
- Direct `update!`, `update_columns`, `update_all`, `delete`, `delete_all`, console
  scripts, fixtures and private-method invocation are trusted low-level APIs.
  They are not automatically intercepted. Production maintenance must use the
  fenced commands or participate in the exclusive drain. Plain Active Record
  credential updates can otherwise change final-copy inputs without a permit.
- New connection creation has no persisted legacy identity to fence before its
  first insert. Existing API/client builders can also perform read-only requests
  independently. Up's personal token has no refresh-token rotation callback in
  these paths, but duplicated grants/new-item creation still require connection
  identity and operator policy at activation.

The shared `DestroyJob` now rethrows ownership/drain denial before its historical
failure handler can reset `scheduled_for_deletion` on a source that no longer
belongs to the legacy writer. That prevents a denied destruction from making an
otherwise unfenced lifecycle update.

Do not cut over Up until the generic account/link/family gates above, copied
credential identity, mapping/evidence parity, and executable financial regression
checks have been completed. Existing malformed-money and pending-pruning behavior
was preserved; this fencing slice does not establish its suitability for native
activation or silently change historical financial semantics.

## Validation

[`UpItem::LegacyWriterTest`](../../test/models/up_item/legacy_writer_test.rb) uses
committed rows and real PostgreSQL advisory locks: native ownership rejects all
listed writers; API and disconnect scheduling hold the drain fence; stale
credentials, snapshots, links, reparented/deleted accounts, family ownership,
processor reuse, setup choices and outer-transaction rejection are exercised.
[`UpItemsControllerTest`](../../test/controllers/up_items_controller_test.rb) covers
the lifecycle delegation, blank-token preservation, denial diagnostics, account
setup and existing admin gate. Existing importer/category/entry normalization
tests retain transactional fixtures and mock only their explicit source boundary;
they do not disable production checks.

No runtime tests or lint have been executed. Static whitespace and caller checks
are limited evidence and do not replace running the focused tests and repository
pre-PR checks in a configured Ruby/PostgreSQL environment.
