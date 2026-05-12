# Goals: account-linked model — engineering mechanics

*Companion to [`goals-architecture.md`](goals-architecture.md). Final cut after five iterations of expert review.*

## Schema

- `goals`: id, family_id, name, target_amount, currency, target_date, color, icon, notes, state.
- `goal_accounts`: id, goal_id, account_id, `allocated_amount decimal NOT NULL DEFAULT 0`, `allocation_mode enum('full_balance', 'fixed_amount')`, currency.
- `goal_balance_snapshots`: goal_id, date, amount, computed_at. `UNIQUE(goal_id, date)`. Rebuild-on-demand cache.
- `goal_activities`: id, goal_id, actor_user_id, action, payload jsonb, `visibility enum DEFAULT 'family'`.
- `accounts.archived_at timestamptz NULL`.
- `accounts.retained_for_goal_id uuid NULL` — soft pointer.
- **Dropped:** `goal_contributions` table, in the same migration train. No dormant scaffolding.

## Computed properties

```ruby
Goal#allocated = goal_accounts.sum do |ga|
  ga.allocation_mode == 'full_balance' ? ga.account.balance : ga.allocated_amount
end

Goal#backed = GoalBacking.for(family).fetch(goal.id, :backed)
```

`GoalBacking` is a request-scoped query object. Single SQL pass, covering index on `goal_accounts(account_id, goal_id) INCLUDE (allocated_amount, allocation_mode)`. Pro-rata in a CTE; returns `(goal_id, account_id, allocated, backed)` rows. Index, show, and funding-widget all read from the same materialized result inside one request.

## Pro-rata under contention

Per linked account with balance B and allocations a₁ … aₙ:

- `Σ aᵢ ≤ B`: each goal backed by aᵢ.
- `Σ aᵢ > B`: each goal backed by `aᵢ × B / Σ aᵢ`.

Fair-share, no priority. Priority ordering is deferred to v1.1; the schema doesn't need to change to add it.

## Pledge reconciliation

Pledge state is held as Stimulus state plus an `extra->goal->pledge_id` UUID stamped on the matched `Entry` after reconciliation. Uniqueness constraint on `pledge_id`. Match runs inside `PlaidEntry::Processor` and the SimpleFIN equivalent: same account, signed amount within ±$0.50 absolute or ±1% (whichever is larger), date within ±5 days, only against rows where `transfer_id IS NOT NULL` (reuses the pace classifier — single source of truth for "saving event"). Pending provider rows do not consume the match.

Multiple open pledges on one account: nearest-amount-first, then nearest-date. Manual-account pledges reconcile against the user's next balance update.

## Sync race against split-prompt commit

Family-level advisory lock on allocation writes via `Goal.advisory_lock_key_for(family_id)`. On commit, re-read balance. If it dropped below `Σ allocations` mid-drag, surface the over-allocation gap inline instead of committing under-water.

## Rate limits

Two clocks:

- **Plaid quota** lives server-side, scoped to `PlaidItem`: 1 manual refresh per 60s, 5/hour, 20/day. Stored on `plaid_items.last_manual_refresh_at` plus a daily-reset counter. Dedicated Sidekiq queue `plaid_manual_refresh`, concurrency 2, so payday-Friday traffic doesn't starve the nightly sync queue. Lockless gate via conditional UPDATE.
- **UI cooldown ring** lives per-goal in the goal-detail Stimulus controller. 60s local. Independent of Plaid bucket state. When the bank bucket is exhausted but the local ring isn't, the button surfaces the bank-side reason ("next slot at 2:14pm") instead of a spinning cooldown.

## Pace

90-day rolling average of family-level net inflow into the goal's linked accounts, computed from `Entry` rows where `transfer_id IS NULL` (or excluded via the `Transfer.exclude` scope, whichever is canonical at implementation time). Top-decile inflows excluded from the pace calculation but visible in the saved area as annotated dots with a per-dot opt-in to apply the windfall to pace.

Window shrinks to available history above 30 days; below 30, no projection segment.

## Snapshot rebuild

`goal_balance_snapshots(goal_id, date)` UNIQUE with `ON CONFLICT (goal_id, date) DO UPDATE SET amount = EXCLUDED.amount, computed_at = NOW()`. Snapshots are a derived cache, not source of truth.

Rebuild on demand for any window where `goals.updated_at > snapshot.computed_at OR goal_accounts.updated_at > snapshot.computed_at`. `GoalSnapshotRebuildJob` is debounced 5 seconds per goal so slider drags don't queue 40 jobs. Read path falls back to live `GoalBacking` if no fresh snapshot covers the date — never a stale number presented as live.

## Account archival

`accounts.archived_at = now()` on close.

- Excluded from `Account#linkable_for_goals`.
- Excluded from `family.total_depository_balance` and the global sidebar.
- Visible inside any goal's funding widget as a muted row, so the saved-series history doesn't break.

`accounts.retained_for_goal_id` is a soft pointer checked on read against `goals.state != 'archived'`. On goal hard-delete, `Goal#before_destroy` callback nullifies the pointer and re-evaluates auto-archive eligibility in the same transaction.

Auto-archive trigger: 180 days no activity AND zero balance AND no linked goals with future `target_date`. Heads-up at 150 days inside the funding widget caption. 30-day reversal grace post-archive.

## Currency

v1 locks `goal_accounts.currency` to `accounts.currency`. Cross-currency goals deferred to v1.1.

## Activity log visibility

`goal_activities.visibility` column NOT NULL DEFAULT `'family'` from day one. Only one value in v1. v1.1 adds `'owner_only'`, `'shared_with'` without a migration on a table already accumulating rows.

## Animation

In-chart pending-segment rendering: third style on the existing `area` generator in `goal_projection_chart_controller.js`, approximately 80 LoC delta. 400ms ease-out (`cubic-bezier(0.4, 0, 0.2, 1)`) on solidify. Snap-cut under `prefers-reduced-motion: reduce`. `aria-live="polite"` on the chart wrapper announces "Transfer matched."

## Day-one instrumentation

- `goal.pledge.created` (`goal_id`, `account_type`, `amount_bucket`)
- `goal.pledge.matched` (`goal_id`, `account_type`, `time_to_match_seconds`)
- `goal.pledge.expired` (`goal_id`, `account_type`)
- `goal.pledge.extended` (`goal_id`)
- Tune ±5 day / ±1% match window if `expired / created > 0.4` in week one.

## Pre-launch user tests

1. **Pledge-pause test.** Mobile Safari, iPhone 13-class, real user with one synced savings account. Task: "You just moved $500 from checking to savings for House. Tell Sure." Signal: pause ≥ 3 seconds on the goal page after confirming, or app close. Pause means the pledge segment is doing its job.
2. **Borrow-frame test.** Real user who already funds two life goals from one savings account. Walk through linking a second goal to an account that fully backs the first. Signal: does "How much should House borrow?" read as fair or as zero-sum theft?
3. **Pledge-expiry-extend ratio.** Instrument the extend-vs-resolve-vs-abandon split on first expiry. Hypothesis: > 60% choose "Extend 7 days." Disproof: < 35% means the pledge isn't carrying weight.
4. **Reconciliation telemetry from day one.** Monitor pledge outcome distribution as above.

## Deferred to v1.1+

Priority ordering, tag-based annotation, auto-fund from budget surplus, FX-aware allocation, family-member-private goals (`goal_activities.visibility` already accommodates), balance-derived weekly-savings indicator.
