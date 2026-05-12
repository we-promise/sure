# Goals: account-linked model — engineering mechanics

*Companion to [`goals-architecture.md`](goals-architecture.md). Grounded in the actual code on `feat/savings-goals` HEAD (commit `a6bdfb73` at time of writing).*

This doc is concrete about what exists in Sure today, what changes, and what's net-new. File:line citations throughout. Verdicts from a fresh read-only audit of the goal-domain code, the account/balance/transfer infrastructure, the four entry processors, and the async/locking surface.

## Current state on the branch (as of `a6bdfb73`)

### Goal-domain models

- `app/models/goal.rb` — 284 lines. AASM states (`active`, `paused`, `completed`, `archived`), validations (linked-account presence, depository-type, family-scope, currency-match, currency-lock-after-contributions), `current_balance` (sums `goal_contributions.amount`), `progress_percent`, `status`, `display_status`, `projection_payload`, `to_donut_segments_json`, `advisory_lock_key_for(family_id)` (lines 41–43, **currently unused**).
- `app/models/goal_contribution.rb` — 57 lines. `belongs_to :goal, :account`. `SOURCES = %w[manual initial]`. Validations.
- `app/models/goal_account.rb` — 7 lines. `belongs_to :goal, :account`. Uniqueness on `(goal_id, account_id)`. **No `allocated_amount` or `allocation_mode` columns today.**

### Schema today

```
goals(id uuid PK, family_id uuid FK, name string, target_amount decimal(19,4),
      currency string, target_date date, color string, icon string, notes text,
      state string default 'active', timestamps)
goal_accounts(id uuid PK, goal_id uuid FK, account_id uuid FK, timestamps)
  index: [goal_id, account_id] UNIQUE
goal_contributions(id uuid PK, goal_id uuid FK, account_id uuid FK,
                   amount decimal(19,4), currency string, source string default 'manual',
                   contributed_at date, notes text, timestamps)
```

### Controllers + AI tool

- `app/controllers/goals_controller.rb` — 312 lines. CRUD + AASM transitions + `kpi_payload`, `funding_breakdown_for`, `stats_for`.
- `app/controllers/goal_contributions_controller.rb` — 65 lines. `new`, `create`, `destroy`.
- `app/models/assistant/function/create_goal.rb` — 185 lines. JSON schema with `linked_account_names`, optional `initial_contribution`.

### UI surface

- 6 components under `app/components/goals/`: avatar, card, status_pill, progress_ring, funding_accounts_breakdown, account_stack.
- 5 Stimulus controllers: `goal_projection_chart_controller.js` (495 lines), `goal_stepper_controller.js` (302 lines), `goals_filter_controller.js` (117 lines), `goal_contribution_preview_controller.js` (67 lines), `color_icon_picker_controller.js` (262 lines, shared with Categories).
- Views under `app/views/goals/` and `app/views/goal_contributions/`.
- Locale files under `config/locales/views/{goals,goal_contributions,layout}/en.yml` and `config/locales/models/{goal,goal_contribution}/en.yml`.

### Account / balance / transfer infrastructure

- **`Account#balance`** is a denormalized cache column. Source-of-truth is `Entry` valuation anchors. Writer: `Account::CurrentBalanceManager#set_current_balance` (`app/models/account/current_balance_manager.rb:33-41`).
- **`balances` table** exists (created in `db/migrate/20240212150110_create_account_balances.rb`). Rich columns: `balance`, `cash_balance`, `start_cash_balance`, `start_non_cash_balance`, `cash_inflows`, `cash_outflows`, `non_cash_inflows`, `non_cash_outflows`, `flows_factor`, plus virtual columns `end_balance`, `start_balance`. Unique index on `(account_id, date, currency)`.
- **No `Account#balance_at(date)` method exists.** Pattern in use: `Balance.where(account_id:, date:)` directly, or `Balance::ChartSeriesBuilder` (`app/models/balance/chart_series_builder.rb`) which uses a CTE with `generate_series` for windowed queries. This is the chart pattern Goals should reuse.
- **No `Family#total_depository_balance`.** Aggregation lives in `BalanceSheet` (`app/models/balance_sheet.rb`) → `BalanceSheet::AccountTotals` → `BalanceSheet::ClassificationGroup` (assets/liabilities).
- **Transfer matching** lives in `Family#auto_transfer_matchable` (`app/models/family/auto_transfer_matchable.rb:51-64`), not in entry processors. `Transfer` rows pair an inflow `Transaction` with an outflow `Transaction`. Entry has `transfer_id` (nullable FK).
- **`Transaction::TRANSFER_KINDS = %w[funds_movement cc_payment loan_payment investment_contribution]`** (`app/models/transaction.rb:79`). Filtering pattern in use: `where.not(kind: Transaction::TRANSFER_KINDS)`. Used by `Entry.uncategorized_transactions`, `Transaction::Search`, rule filters.
- **`Account.manual` scope** (`app/models/account.rb:35-39`): no `account_providers`, no `plaid_account_id`, no `simplefin_account_id`.
- **`Account.visible` scope** (`app/models/account.rb:31`): `status IN ("draft", "active")`. Account uses AASM `status` (`:active`, `:draft`, `:disabled`, `:pending_deletion`) — **no `archived_at` column**.
- **`Depository::SUBTYPES`** (`app/models/depository.rb:4-10`): `checking`, `savings`, `hsa`, `cd`, `money_market`. Exactly the subtype distinctions the architecture needs.

### Entry processors and `extra` jsonb

- Four entry processors: `PlaidEntry::Processor` (`app/models/plaid_entry/processor.rb`), `SimplefinEntry::Processor`, `LunchflowEntry::Processor`, `EnableBankingEntry::Processor`. All four call `Account::ProviderImportAdapter#import_transaction` (`app/models/account/provider_import_adapter.rb:29-242`) — the hub.
- **`extra` jsonb lives on `Transaction`**, not `Entry` directly (`db/migrate/20251029190000_add_extra_to_transactions.rb`). GIN-indexed.
- **Existing `extra` namespaces** stamped today: `simplefin`, `plaid`, `lunchflow`, `enable_banking`, `exchange_rate`, `potential_posted_match`, `manual_merge`. **`extra["goal"]` is free** — no collision.
- **Existing partial-unique index precedent**: `add_index :entries, [:external_id, :source], unique: true, where: "external_id IS NOT NULL AND source IS NOT NULL"` (`db/migrate/20251027110502_*.rb`).

### Async + locking

- **`SyncJob`** (`app/jobs/sync_job.rb`). Queue: `high_priority`. Concurrency 4.
- **`Goal.advisory_lock_key_for(family_id)`** at `app/models/goal.rb:41-43`. Currently **unused** — wired pattern doesn't exist yet.
- **Existing advisory-lock pattern**: `IdentifyRecurringTransactionsJob#with_advisory_lock` (`app/jobs/identify_recurring_transactions_job.rb:62-77`). Uses `pg_try_advisory_lock` + `pg_advisory_unlock` with ensure-block release. Copy this pattern verbatim for goal-allocation writes.
- **Sidekiq queues** (`config/sidekiq.yml`): `scheduled` (10), `high_priority` (4), `medium_priority` (2), `low_priority` (1), `default` (1). **No manual-refresh queue today.** Add `plaid_manual_refresh` to the config.
- **PlaidItem** does not have `last_manual_refresh_at` or per-day-counter columns today. Migration required.

## What changes

### Schema migrations (in order)

**1. Add allocation columns to `goal_accounts`:**

```ruby
# db/migrate/<ts>_add_allocation_to_goal_accounts.rb
add_column :goal_accounts, :allocated_amount, :decimal, precision: 19, scale: 4, null: false, default: 0
create_enum :goal_account_allocation_mode, %w[full_balance fixed_amount]
add_column :goal_accounts, :allocation_mode, :goal_account_allocation_mode, null: false, default: "full_balance"
add_index  :goal_accounts, [:account_id, :goal_id], include: [:allocated_amount, :allocation_mode], name: "ix_goal_accounts_backing"
```

The covering index keeps `GoalBacking` queries index-only.

**2. Create `goal_balance_snapshots`:**

```ruby
create_table :goal_balance_snapshots, id: :uuid do |t|
  t.references :goal, type: :uuid, null: false, foreign_key: true
  t.date :date, null: false
  t.decimal :amount, precision: 19, scale: 4, null: false
  t.timestamp :computed_at, null: false
end
add_index :goal_balance_snapshots, [:goal_id, :date], unique: true
```

Per Daniel's matrix call: `account_id` is omitted. Per-account sparklines render live from `GoalBacking`.

**3. Create `goal_activities`:**

```ruby
create_enum :goal_activity_visibility, %w[family owner_only shared_with]
create_table :goal_activities, id: :uuid do |t|
  t.references :goal, type: :uuid, null: false, foreign_key: true
  t.references :actor_user, type: :uuid, foreign_key: { to_table: :users }
  t.string :action, null: false
  t.jsonb :payload, null: false, default: {}
  t.column :visibility, :goal_activity_visibility, null: false, default: "family"
  t.timestamps
end
add_index :goal_activities, [:goal_id, :created_at]
```

v1 writes only `'family'`. `'owner_only'`, `'shared_with'` are v1.1 — no further migration.

**4. Add Plaid manual-refresh throttle columns:**

```ruby
add_column :plaid_items, :last_manual_refresh_at, :datetime
add_column :plaid_items, :manual_refresh_count_day, :integer, null: false, default: 0
add_column :plaid_items, :manual_refresh_count_date, :date
```

The `count_date` lets a Sidekiq cron reset counters at midnight UTC without a separate truncate.

**5. Account goal-retention state.** Sure doesn't use `archived_at` — accounts have an AASM `status`. Add a new state rather than introducing a parallel column:

```ruby
# Update the Account enum check constraint:
# status IN ('active', 'draft', 'disabled', 'pending_deletion', 'goal_retained')
add_column :accounts, :retained_for_goal_id, :uuid
add_index  :accounts, :retained_for_goal_id, where: "retained_for_goal_id IS NOT NULL"
```

Update `Account.visible` scope to exclude `goal_retained`. Update `BalanceSheet::NetWorthSeriesBuilder#visible_account_ids` accordingly.

**6. Add `pledge_id` unique constraint on `transactions.extra`:**

```ruby
add_index :transactions, "(extra -> 'goal' ->> 'pledge_id')",
  unique: true,
  where: "(extra -> 'goal' ->> 'pledge_id') IS NOT NULL",
  name: "ix_transactions_extra_goal_pledge_id"
```

Mirrors the `entries[:external_id, :source]` partial-unique precedent.

**7. Drop `goal_contributions`:**

```ruby
drop_table :goal_contributions
```

Same migration train. No dormant scaffolding — the previous five iterations of expert review unanimously rejected leaving it as a half-decision.

### Models touched

- `app/models/goal.rb`:
  - Replace `current_balance` (today: `goal_contributions.sum(:amount)`) with `allocated` (sum of `goal_accounts.allocated_amount` or `account.balance` per `allocation_mode`).
  - Add `backed` (delegates to `GoalBacking` query object).
  - Remove `last_contribution_at`, `last_contribution_days_ago`, `average_monthly_contribution`. Their replacements are derived from `Balance` history.
  - Update `projection_payload` to source `saved_series` from `Balance` history × allocation share, not contribution sum.
  - Drop `attr_accessor :initial_contribution_amount, :initial_contribution_account_id` virtual attrs.
  - Drop `has_many :goal_contributions`.
  - Add `has_many :goal_activities`.
  - Validations: remove `currency_locked_once_contributions_exist`. Add allocation-mode-currency-consistency.
- `app/models/goal_account.rb`: add `validates :allocated_amount, numericality: { greater_than_or_equal_to: 0 }`. Add allocation_mode predicate.
- **Delete** `app/models/goal_contribution.rb`.

### New service / query objects

- `app/models/goal_backing.rb` — request-scoped query object. Single SQL pass using the covering index. Returns `(goal_id, account_id, allocated, backed)` rows. Replaces both `Goal#current_balance_total` SQL and per-row pro-rata math.
- `app/models/goal/pledge.rb` — pledge state model. Stimulus controller + Rails-side row. Fields: `id`, `goal_id`, `account_id`, `amount`, `expires_at`, `status` (`pending|matched|expired|extended|cancelled`).
- `app/jobs/goal_snapshot_rebuild_job.rb` — debounced 5s per `(goal_id, family_id)`. Reads from `GoalBacking`, upserts `goal_balance_snapshots`.
- `app/jobs/plaid_manual_refresh_job.rb` — wraps a Plaid sync. New queue: `plaid_manual_refresh` (concurrency 2 in `config/sidekiq.yml`).

### Pledge reconciliation hook

Pledge matching runs **inside `Account::ProviderImportAdapter#import_transaction`** (`app/models/account/provider_import_adapter.rb:29-242`), specifically after the existing pending-to-posted reconciliation block (currently lines 79–115) and before the `Transaction#save` call.

```ruby
# Pseudocode for the new reconciliation step:
if pledge = matching_pledge_for(account_id: entry.account_id, amount: entry.amount, date: entry.date)
  transaction.extra["goal"] = { "pledge_id" => pledge.id, "matched_at" => Time.current }
  pledge.update!(status: :matched, matched_entry_id: entry.id)
end
```

The match runs against rows where `transfer_id IS NOT NULL` (the entry is already paired into a Transfer by the post-sync `Family#auto_transfer_matchable` pass). Tolerance: ±5 days / ±$0.50 absolute or ±1% (whichever is larger). Multiple open pledges on one account: nearest-amount-first, then nearest-date. The partial-unique index on `transactions.extra->goal->>pledge_id` enforces first-match-wins at the DB level — second deposit matching the same pledge is just a deposit.

### Advisory-lock wiring

Goal allocation writes go through a serializer using the existing `Goal.advisory_lock_key_for(family_id)` method plus the existing `IdentifyRecurringTransactionsJob#with_advisory_lock` pattern, lifted into a `Goal::AllocationWriter` service:

```ruby
# app/models/goal/allocation_writer.rb (pseudocode)
def write!(family_id, allocations)
  lock_key = Goal.advisory_lock_key_for(family_id)
  acquired = ActiveRecord::Base.connection.select_value(
    ActiveRecord::Base.sanitize_sql_array(["SELECT pg_try_advisory_lock(?)", lock_key])
  )
  return :busy unless acquired
  begin
    ActiveRecord::Base.transaction do
      allocations.each(&:save!)
      re_read_balance_and_validate!
    end
  ensure
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array(["SELECT pg_advisory_unlock(?)", lock_key])
    )
  end
end
```

The `re_read_balance_and_validate!` step is what catches sync-against-split-prompt races: if a balance dropped mid-drag, surface the over-allocation gap inline instead of committing under-water.

### Snapshot rebuild

`GoalSnapshotRebuildJob` debounce key is `(goal_id, family_id)` — Daniel's matrix correction. On any `goal_accounts` write (including a sibling goal's allocation change on the same account), enqueue with that key. Sidekiq's `unique_for` window of 5 seconds collapses slider-drag bursts.

On retroactive allocation edits, the job's read path: `WHERE goals.updated_at > snapshot.computed_at OR goal_accounts.updated_at > snapshot.computed_at` for the affected date window only (not since-account-creation). Read fallback: live `GoalBacking` if no fresh snapshot covers the date — never a stale number presented as live.

### Pace and projection chart

Pace queries reuse the `Balance::ChartSeriesBuilder` CTE pattern (`app/models/balance/chart_series_builder.rb:38-83`). Filter on `Transaction.where.not(kind: Transaction::TRANSFER_KINDS)` for excluding inter-account moves. Top-decile inflow exclusion happens in Ruby on the result set — 90 days of data is small enough.

Projection chart controller (`goal_projection_chart_controller.js`) gets a third `<path>` element on the existing `area` generator: `confirmed_series`, `pending_series`, `projection_dashed`. Three styles, same generator, ~80 LoC delta. Animation: `cubic-bezier(0.4, 0, 0.2, 1)` at 400ms (Tailwind default `ease-out`). `prefers-reduced-motion: reduce` → snap-cut. `aria-live="polite"` on the chart wrapper announces "Transfer matched."

### Rate-limit infrastructure

Per-`PlaidItem` rate-limit gate is a lockless conditional UPDATE, mirroring `Security::HealthChecker`'s `where(last_health_check_at: ..INTERVAL.ago)` pattern (`app/models/security/health_checker.rb:126`):

```ruby
PlaidItem.where(id: plaid_item.id)
         .where("last_manual_refresh_at < ?", 60.seconds.ago)
         .update_all(last_manual_refresh_at: Time.current,
                     manual_refresh_count_day: <<...>>)
# update_all returns row-count. 0 = throttled.
```

UI cooldown ring lives entirely in `goal_detail_controller.js` (new) — 60s local timer, independent of server state. When the server returns 429, the button surfaces the bank-side reason ("next slot at 2:14pm") instead of a spinning cooldown that lies about why.

## UI surface verdict

From the read-only audit. STAY = no change. CHANGE = same surface, new data source / new copy. DELETE = goes away.

| Surface | Verdict | Notes |
|---|---|---|
| `Goals::AvatarComponent` (rb + erb) | STAY | Pure UI. |
| `Goals::StatusPillComponent` (rb + erb) | STAY | Status logic shifts to `display_status` derived from `backed`; component itself is reusable. |
| `Goals::AccountStackComponent` (rb + erb) | STAY | Index card avatar stack. |
| `Goals::ProgressRingComponent` (rb + erb) | CHANGE | Numerator becomes `Goal#backed` (or `allocated` — design pick). Denominator unchanged. |
| `Goals::CardComponent` | CHANGE | Drop `pace_line`, `footer_line` (no contributions). Show share-of-account-backing per linked account in the avatar stack. |
| `Goals::FundingAccountsBreakdownComponent` | CHANGE | Rename internal data source from `goal_contributions.group(:account)` to `GoalBacking` rows. Add 90-day per-account sparkline. Add "Also funding N other goals" caption. |
| `goal_projection_chart_controller.js` | CHANGE | New `pending_series` path. `saved_series` data source swaps from contributions to `Balance` history × allocation share. |
| `goal_stepper_controller.js` | CHANGE | Step 2's `initialContributionAmount` / `initialContributionAccountSelect` targets → `allocationInputs[]`. Validation logic shifts from "min contribution" to "allocation per account ≤ account.balance." |
| `goals_filter_controller.js` | CHANGE | Status chip set unchanged in structure; data feeds `backed`-derived `:behind`. |
| `goal_contribution_preview_controller.js` | DELETE | Contribution form is gone. |
| `color_icon_picker_controller.js` | STAY | Shared with Categories. |
| `app/views/goals/index.html.erb` | CHANGE | KPI strip: `Unallocated` chip added. `velocity_30d` data source swaps to `Balance`-history-derived. |
| `app/views/goals/show.html.erb` | CHANGE | Replace `_contributions_list.html.erb` render with the funding-widget per-account expand. Drop "Add contribution" action button. Add "I just transferred" / "I just saved" verb-branched action. |
| `app/views/goals/new.html.erb` + `_form_stepper.html.erb` | CHANGE | Step 1 keeps name/target/date/color/icon/accounts/notes. Step 2 replaces "initial contribution" disclosure with optional per-account allocation inputs. |
| `app/views/goals/edit.html.erb` + `_form_edit.html.erb` | CHANGE | Add per-account allocation inputs. |
| `app/views/goals/_color_picker.html.erb` | STAY | Unchanged. |
| `app/views/goals/_contributions_list.html.erb` | DELETE | |
| `app/views/goal_contributions/new.html.erb` | DELETE | Replaced by a new `goal_pledges/new.html.erb` for the "I just transferred" sheet. |
| `app/controllers/goals_controller.rb` | CHANGE | `kpi_payload` data sources rewritten. `funding_breakdown_for` swaps to `GoalBacking` rows. `sync_linked_accounts!` extended with allocation diff handling. |
| `app/controllers/goal_contributions_controller.rb` | DELETE | Replaced by `Goal::PledgesController`. |
| `app/models/assistant/function/create_goal.rb` | CHANGE | JSON schema: drop `initial_contribution`. Add `allocation_per_account` (optional). Logic simplified — no `create_initial_contribution_if_provided!`. |
| `app/models/demo/generator.rb#generate_goals!` | CHANGE | Stop creating contributions. Set `goal_accounts.allocated_amount` directly. Use `Account#balance` history to give the projection chart shape. |

## Test changes

- `test/models/goal_test.rb` — rewrite all tests touching `current_balance` and contributions. Add tests for `allocated`, `backed`, `GoalBacking` aggregation, allocation_mode transitions on contention.
- `test/models/goal_contribution_test.rb` — delete.
- `test/controllers/goals_controller_test.rb` — drop `with initial contribution` flow. Replace with allocation-on-create flow.
- `test/controllers/goal_contributions_controller_test.rb` — delete. Replace with `test/controllers/goal/pledges_controller_test.rb`.
- `test/models/assistant/function/create_goal_test.rb` — update json schema test. Drop initial-contribution tests.
- Fixtures: `goal_contributions.yml` deleted. `goal_accounts.yml` updated with `allocated_amount` and `allocation_mode`.

## Day-one instrumentation

- `goal.pledge.created` (goal_id, account_id, account_type, amount_bucket)
- `goal.pledge.matched` (goal_id, account_id, time_to_match_seconds)
- `goal.pledge.expired` (goal_id, account_id)
- `goal.pledge.extended` (goal_id)
- `goal.allocation.committed_under_water` (goal_id, account_id, gap_amount) — telemetry for the split-prompt-vs-sync race.
- `goal.snapshot_rebuild.duration` — watch the p99 for sibling-fanout regressions.

If `expired / created > 0.4` in week one, tune the ±5 day / ±1% match window.

## Pre-launch user tests

1. **Pledge-pause test.** Mobile Safari, iPhone 13-class, real user with one synced savings account. Task: "You just moved $500 from checking to savings for House. Tell Sure." Signal: pause ≥ 3 seconds on the goal page after confirming.
2. **Borrow-frame test.** Real user already funding two goals from one account. Walk through linking a second goal to a shared account. Signal: does "How much should House borrow?" parse as fair or as theft?
3. **Pledge-expiry-extend ratio.** Instrument the extend-vs-resolve-vs-abandon split on first expiry. Hypothesis: > 60% choose "Extend 7 days." Disproof: < 35% means the pledge isn't carrying weight.
4. **Overlap legibility (Tessa's test).** Six users running 3+ active goals across 2+ accounts. Show them the funding-widget overlap line. Ask: "If you spent $500 from Ally tomorrow, which goal would feel it?" Score: how many name the mathematically correct goal vs. the goal with the largest Ally allocation. < 50% correct = pro-rata is correct but illegible, widget needs a visual cue beyond text.

## Deferred to v1.1+

Priority ordering for the over-allocation split. Tag-based annotation. Auto-fund from budget surplus. FX-aware allocation (v1 locks `goal_accounts.currency` to `accounts.currency`). Family-member-private goals (schema breadcrumb is in place via `goal_activities.visibility`). Balance-derived weekly-savings indicator. Auto-rebalancing on sibling-goal allocation changes (v1 ships the preview-diff, v1.1 considers auto-applying with confirmation).
