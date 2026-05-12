# Goals: how the balance is computed

*Posted 2026-05-12. Tied to PR [#1757](https://github.com/we-promise/sure/pull/1757) on branch `feat/savings-goals`. Final cut after five iterations of expert review plus a focused matrix pass and a code-reality audit.*

A Goal is a target. Its balance is the live balance of the savings accounts linked to it, minus what other goals have claimed from those same accounts. No "log a goal contribution." No parallel ledger.

## What this looks like in practice

Make a goal called House, target $50K. Link Ally savings ($13K). Goal shows $13K, 26%. Two months later Ally has grown to $15K because you've been saving — goal shows $15K, 30%. Three months later you transfer $3K out for a car repair — goal shows $12K. The projection chart reflects every change.

## How "saving" still feels like an act

The action button reads **"I just transferred"** on goals backed by bank-connected accounts, **"I just saved"** on goals backed by manual accounts only. Tap it, enter $500, and the projection chart renders a translucent pending segment from today to seven days out, anchored to your pledged date. When your bank sync posts a matching transfer (within ±5 days, amount within ±$0.50 or ±1%), the segment solidifies in place with a 400ms ease-out. Screen readers announce "Transfer matched." For manual accounts, the pledge resolves on your next manual balance edit and the segment solidifies immediately.

If the window expires without a match: "Still planning this transfer? Extend the window 7 days, or mark it done elsewhere."

A "Refresh sync" button forces an immediate bank pull. UI cooldown is per-goal (60 seconds). The Plaid quota is separate (1/min, 5/hour, 20/day). If the bank bucket is exhausted but the goal's local cooldown isn't, the button reads "Bank refresh limit reached — next slot at 2:14pm."

## When a goal pulls from multiple accounts (1 × M)

A House goal can be backed by Ally, Chase Savings, and an HSA at the same time. Each linked account is shown in the funding widget as its own row with a 90-day sparkline of that account's contribution to the goal — the user grasps which account is actually doing the work, not just which one has the largest balance.

**Defaults at link time depend on subtype.** Checking, savings, and money-market accounts default to "fully count toward the goal." HSA, CD, and other restricted-use subtypes default to **excluded** with a one-tap "include this account" affordance. The misuse cost on those subtypes is high enough that the default flips to honest-by-default.

**Rows in the funding widget are ordered by recency of net contribution**, not by largest balance. The account doing the saving sits on top; passive holders sink. A thin "last-30 days" overlay on the segment bar shows where the money is flowing now.

**One pending segment, not three.** When you mark a transfer, the projection chart shows one goal-level pending segment, not one per account. Tapping the dot lists which account the pledge is bound to.

**Pledge account selection.** The pledge sheet pre-selects the account with the largest matching-direction transfer in the last 14 days into this goal. If two accounts are within 15% of each other on that metric, no pre-selection — both are shown, the user picks.

**Catch-up copy attributes the slowdown.** When pace slips on a 1×M goal, the banner doesn't say "save $X/mo more." It says "Ally inflow halved last month. Move from checking, or adjust your target?"

## When one account funds multiple goals (N × 1)

The split prompt opens as a question, not a default to confirm: "Ally has $15K. It currently fully backs Emergency Fund. How much should House borrow?"

Above the sliders, a lead line: **"These sliders label your savings. They don't move anything."** Users early in the feature read sliders as "moving money" instead of "labeling intent" — the line resolves that.

Sliders start at **proportional-to-remaining-need**; open-ended goals' current allocation is the floor. Time-to-target labels update live on each affected dated goal. Two peer affordances live below the sliders:

- **Concentrate on the next deadline** — all flow to the soonest-dated goal.
- **Distribute by deadline urgency** — weight allocations by `1 / months_remaining`. Bigger weight for closer deadlines.

At 3+ goals on one account: a list of stepper rows replaces the slider stack. The segment bar above the list stays as a read-only summary.

Joint accounts: splits are proposals the other partner accepts. Every accept, reject, or edit lands in a goal-level activity log with the diff. Selecting a joint account at goal-create surfaces a disclosure: "Goals on shared accounts are visible to everyone on the account."

## When goals share accounts (N × M, the partial-overlap case)

Three goals can share Ally while two also share Chase. Each goal's funding widget surfaces a quiet line under the heading: **"Ally also funds 2 other goals."** Overlap becomes explicit at the goal level where decisions are made, not buried at the account level.

**Editing one goal's accounts triggers a preview diff** before save. "Removing Marcus Invest from Vacation will leave Vacation $2.4K backed on Ally. Continue?" This is the cell where pro-rata under contention turns into a coaching emergency — silent sibling-goal allocation changes are the most-cited frustration with this design pattern.

**Reallocation flow.** A first-class action: source goal → destination goal → amount → optional reason. Writes two activity rows atomically and shows the segment-bar diff animation on both goals.

**"Why is this goal behind?" diagnostic.** Tap the chevron on the catch-up callout to expand: "Pace dropped from $1,200/mo to $480/mo in the last 30 days. Ally inflow halved." This is the moment a user either trusts the model or reaches for a spreadsheet.

## When the math doesn't work out

"Allocated $10K · Backed by $8.13K · Reserved beyond balance $2K." Pro-rata under contention. When a deposit clears the shortfall on the next sync, a transient toast: "Your paycheck covered House's shortfall."

When you spend from a savings account holding multiple allocations, the post-spend reconciliation prompt names the allocation that absorbed it and offers a one-tap "restore later."

**Special error state.** Shortfall caused by an archived account: a dedicated banner replaces the catch-up callout. "$7.8K is in an archived account · Restore Ally, or re-link this goal to another account."

## Pace, projection, and windfalls

Pace is a 90-day rolling average of net inflow into linked accounts, excluding inter-account transfers (filters on `Transaction#kind NOT IN TRANSFER_KINDS`). Top-decile inflows show as annotated dots in the saved area: "counted toward total · tap to include in pace too." Tap to apply a windfall to pace; the dot pulses on first appearance per session.

Passive growth on a single linked account — interest, employer match, a deposit that wasn't a real act of saving — gets the same dimmed annotation treatment as windfalls. The user sees the growth but the system doesn't pretend it was earned through goal-directed effort.

Accounts with less than 90 days of balance history use what's available, down to a 30-day minimum. Below 30: no projection.

## Unallocated cash and runway

The `/goals` index shows an "Unallocated" chip in the KPI strip: balance left in savings, HSA, CD, and money-market accounts after every allocation is counted. Checking is excluded because it's operational and would thrash. **Tapping the chip opens a sheet** listing the unallocated amount per account, sorted by size, with each row clickable to "Allocate to a goal." The KPI is a prompt, not just a number.

Open-ended goals (no target date) show **months-of-runway** instead of progress-to-target — that goal's balance divided by the family's 90-day average monthly outflow, excluding transfers and income. Capped at "12+ months." Below 30 days of outflow history, the chip is hidden rather than guessed at.

## When an account is closed at the bank

The account is moved into a goal-retention state, not deleted. It disappears from the global sidebar, family-level totals, and the linkable-accounts list. It stays visible inside the goal's funding widget as a muted row so the goal's history doesn't break. Restoring it is one tap in settings.

Auto-archive happens at 180 days no activity AND zero balance, only for goals without a future target date. Calendar-driven goals don't auto-archive. A heads-up appears at 150 days inside the funding widget. Archived accounts have a 30-day reversal grace.

## Per-goal history

Inside the funding widget, each linked account expands into a sparkline of its contribution to the goal plus a list of net inflows ≥ $100 with `View transaction` links. This replaces the contributions list.

## What's not in v1

Priority ordering for the over-allocation split. Tag-based contribution annotation. Auto-fund from budget surplus. FX-aware allocation when the goal and account currencies differ. Family-member-private goals. A balance-derived weekly-savings indicator. Sibling-goal allocation auto-rebalancing.

Engineering specifics, schema deltas, and migration plan in the [mechanics doc](goals-architecture-mechanics.md).
