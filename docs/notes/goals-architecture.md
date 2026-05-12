# Goals: how the balance is computed

*Posted 2026-05-12. Tied to PR [#1757](https://github.com/we-promise/sure/pull/1757) on branch `feat/savings-goals`. Final cut after five iterations of expert review.*

A Goal is a target. Its balance is the live balance of the savings accounts linked to it, minus what other goals have claimed from those same accounts. No "log a goal contribution." No parallel ledger.

## What this looks like in practice

Make a goal called House, target $50K. Link Ally savings ($13K). Goal shows $13K, 26%. Two months later Ally has grown to $15K because you've been saving — goal shows $15K, 30%. Three months later you transfer $3K out for a car repair — goal shows $12K. The projection chart reflects every change.

## How "saving" still feels like an act

The action button reads **"I just transferred"** on goals backed by bank-connected accounts, **"I just saved"** on goals backed by manual accounts only. Tap it, enter $500, and the projection chart renders a translucent pending segment from today to seven days out, anchored to your pledged date. When your bank sync posts a matching `Transfer` (within ±5 days, amount within ±$0.50 or ±1%), the segment solidifies in place with a 400ms ease-out. Screen readers announce "Transfer matched." For manual accounts, the pledge resolves on your next manual balance edit and the segment solidifies immediately.

If the window expires without a match: "Still planning this transfer? Extend the window 7 days, or mark it done elsewhere."

A "Refresh sync" button forces an immediate bank pull. UI cooldown is per-goal (60 seconds). The Plaid quota is separate (1/min, 5/hour, 20/day). If the bank bucket is exhausted but the goal's local cooldown isn't, the button reads "Bank refresh limit reached — next slot at 2:14pm."

## When one account funds two goals

The split prompt opens as a question: "Ally has $15K. It currently fully backs Emergency Fund. How much should House borrow?"

Sliders start at proportional-to-remaining-need; open-ended goals' current allocation is the floor. Time-to-target labels update live as you drag. A one-tap "Concentrate on the next deadline" routes everything to the soonest-dated goal.

Three or more goals on one account: a list of stepper rows with the segment bar above as a read-only summary.

Joint accounts: splits are proposals the other partner accepts. Every accept, reject, or edit lands in a goal-level activity log with the diff. Selecting a joint account at goal-create surfaces a disclosure: "Goals on shared accounts are visible to everyone on the account."

## When the math doesn't work out

"Allocated $10K · Backed by $8.13K · Reserved beyond balance $2K." Pro-rata under contention. When a deposit clears the shortfall on the next sync, a transient toast: "Your paycheck covered House's shortfall."

When you spend from a savings account holding multiple allocations, the post-spend reconciliation prompt names the allocation that absorbed it and offers a one-tap "restore later."

**Special error state.** Shortfall caused by an archived account: a dedicated banner replaces the catch-up callout. "$7.8K is in an archived account · Restore Ally, or re-link this goal to another account."

## Pace, projection, and windfalls

Pace is a 90-day rolling average of net `Transfer.exclude` inflow into linked accounts. Top-decile inflows show as annotated dots in the saved area: "counted toward total · tap to include in pace too." Tap the dot to apply a windfall to pace; the dot pulses on first appearance per session.

Accounts with less than 90 days of balance history use what's available, down to a 30-day minimum. Below 30: no projection.

## Unallocated cash and runway

The `/goals` index shows an "Unallocated" chip in the KPI strip: balance left in savings, HSA, CD, and money-market accounts after every allocation is counted. Checking is excluded because it's operational and would thrash.

Open-ended goals (no target date) show **months-of-runway** instead of progress-to-target — that goal's balance divided by the family's 90-day average monthly outflow, excluding transfers and income. Capped at "12+ months." Below 30 days of outflow history, the chip is hidden rather than guessed at.

## When an account is closed at the bank

The account is archived in place, not deleted. It disappears from the global sidebar, family totals, and the linkable-accounts list. It stays visible inside the goal's funding widget as a muted row so the goal's history doesn't break. Restoring it is one tap in settings.

Auto-archive happens at 180 days no activity AND zero balance, only for goals without a future target date. Calendar-driven goals don't auto-archive. A heads-up appears at 150 days inside the funding widget. Archived accounts have a 30-day reversal grace.

## Per-goal history

Inside the funding widget, each linked account expands into a sparkline of its contribution to the goal plus a list of net inflows ≥ $100 with `View transaction` links. This replaces the contributions list.

## What's not in v1

Priority ordering for the over-allocation split. Tag-based contribution annotation. Auto-fund from budget surplus. FX-aware allocation when the goal and account currencies differ. Family-member-private goals. A balance-derived weekly-savings indicator.

Engineering specifics in the [mechanics doc](goals-architecture-mechanics.md).
