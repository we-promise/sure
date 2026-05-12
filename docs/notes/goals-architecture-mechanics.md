# Goals: account-linked model — engineering mechanics

*Posted 2026-05-12. Companion to [`goals-architecture.md`](goals-architecture.md). Engineering-facing detail behind the user-facing summary.*

## What changes for users (recap)

You set a goal. You link the accounts that hold the money for it. Whatever those accounts hold is your goal's balance. No "add contribution" step. The goal updates next time Sure syncs.

## Schema

```
goals: (unchanged from current branch)
goal_accounts: id, goal_id, account_id, allocated_amount NULL, currency
goal_contributions: dropped
```

`Goal#allocated`: sum of allocation amounts (NULL means full balance).
`Goal#backed`: pro-rata of allocations against actual account balance when contended.

## Pro-rata under contention

Account balance B, allocations a₁ … aₙ:

- `Σ aᵢ ≤ B`: each goal backed by aᵢ.
- `Σ aᵢ > B`: each goal backed by `aᵢ × B / Σ aᵢ`.

Fair-share, no priority. Priority is a v2 question and is explicitly deferred. The schema doesn't lock the door.

## Over-allocation

When `allocated > backed`, the goal shows: "Allocated $5K · Backed by $3K · Uncovered by $2K." Projection chart and status pill use intent. The user has three one-click affordances: reduce allocation, transfer in, accept.

## Unallocated

Per account: `balance − Σ allocations`. Top-level on `/goals`: sum across linked savings. Label: "Unallocated."

## Defaults

Single goal on an account, no explicit allocation: `allocated_amount = NULL`, full balance counts.

Second goal added to the same account triggers a split prompt. Two goals: slider, defaults to 50/50. Three or more: numeric inputs summing to ≤ balance, defaults to equal split.

## Pace and projection

Pace is the rolling 90-day average of total linked-account balance change, weighted by allocation.

Accounts with less than 90 days of history use whatever's available, down to a 30-day minimum. The 30-day threshold is where short-term volatility (one payday, one large transfer) stops dominating the slope. Below 30 days: no projection, just the saved area.

Net negative growth over the window: projection line goes flat or down. Status reads "Behind."

## Manual accounts

A manual account works identically. The user maintains the balance; the goal follows.

## Un-link and delete

Un-link: allocation row removed, goal balance drops by the allocation amount.

Delete: prompt to re-link or remove the goals. No silent cascade.

## Gains and losses

- Loss: the "I saved $200 today" ritual.
- Gain: the goal balance never lies. Spend from savings, goal shrinks.
- Loss: the add-contribution modal and live impact preview.
- Gain: the projection chart reflects reality. Income drops, projection drops.
- Loss: roughly 30% of the v1 surface (contribution model, controller, views, Stimulus).
- Gain: no double-entry. What's in the bank is what's in the goal.

## What stays

Goal model, AASM states, index page, KPI strip, status pills, projection chart visual, color and icon picker, avatar component, AI tool, demo seed.
