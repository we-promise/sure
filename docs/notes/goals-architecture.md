# Goals architecture: account-linked, or what we have now?

*Posted 2026-05-12. Tied to PR [#1757](https://github.com/we-promise/sure/pull/1757) on branch `feat/savings-goals`.*

A Discord thread with Juanjo and CrossDrain surfaced a question worth resolving before PR #1757 merges: does the Goals data model accurately reflect what it claims to track? The branch ships a working version, but the underlying shape may need to change before users see it.

This document is not an ADR. The repo doesn't run that practice. Treat it as a discussion doc. Opinions welcome.

## What's on the branch

A Goal has a name, a target ("save $50K for a house"), one or more linked savings accounts, and a manual contribution log. Contributions live in their own table, separate from real transactions. Adding a contribution increments the goal balance but doesn't touch the bank balance or transaction list. The result is a parallel ledger.

The stepper currently displays the string "Balances in these accounts will count toward the goal." Under the current model, balances don't count. Only manually logged contributions count.

Other gaps surface in extended use.

Example: a user adds a $5K contribution toward a savings goal, then in a later month transfers $3K of that balance from savings to checking to pay rent. The goal continues to show $5K saved, even though the money is gone.

Account selection at goal creation appears to be a commitment, but functionally it only filters which accounts appear in the contribution dropdown later.

The question: is this the model to ship, or should it change first?

## The three shapes other apps use

Personal-finance apps land in one of three answers to "what does a goal's balance represent."

**Account-linked.** The goal references one or more savings accounts and derives its balance from them. The number on the goal page is the live balance of the account. No manual logging. Monarch, Copilot, and the old Mint use this shape. When one account funds multiple goals, the account balance is split via explicit allocations: "$5K of this $20K is for House, $3K is for Vacation."

**Tag-based.** A contribution is a real transaction with a tag. When money moves into savings, the inflow transaction is tagged "Goal: House," and the goal's balance is the sum of tagged inflows. Closer to YNAB's envelope model, but built on Sure's existing tag system. This is the direction Juanjo proposed on Discord.

**Free-form ledger.** Goals have their own contribution table, decoupled from real transactions. This is the shape on the branch. Mainly seen in lower-end aggregators.

## Trade-offs

Account-linked aligns the goal balance with the real account state. Nothing requires maintenance once the link is set up. Spending from a linked account reduces the goal balance automatically. The constraint is that a shared account requires an explicit allocation mechanism for splitting across goals.

Tag-based reuses an existing Sure primitive (tags) and ties goal progress to real money flow. Limitations: "earmarking $5K of an existing balance for House" isn't a transaction event but a snapshot, which tags don't model. Tags fit new inflows; they don't fit pre-existing balances. The tagging UX on the transaction side is itself a feature that doesn't exist today and would need to be built first.

Free-form ledger has the lowest implementation cost. It is also the only shape of the three that does not reconcile with the user's actual account balances.

## Proposed direction

Account-linked, applied before merge.

Migration cost: zero. The branch is pre-ship. No user data needs migration.

Code cost: mostly deletion. Drop the contribution model, the contribution controller and views, the live impact preview, and the parts of the stepper that assume contributions. What stays is the goal model itself, the projection chart (whose data source becomes account balance history, which Sure already tracks via the `balances` table), the status pills, the color and icon picker, the AI tool, and the demo seed.

Post-ship cost of the alternative: each user whose goal balance diverges from their account balance becomes a support question. A later migration off the parallel ledger is more expensive than a pre-ship change.

A counter-argument exists for shipping the current model and iterating. The trade-off is that the contribution-logging UX requires the user to manually keep two systems in sync.

## What stays the same either way

The decision is about how a goal's balance gets computed. The feature itself remains.

- The `/goals` page, KPI strip, ongoing / completed / archived sections.
- Status pills (`On track`, `Behind`, `Reached`, `Open`, `Paused`, `Archived`) and the `Goal#display_status` logic.
- Projection chart: same shape, same interactivity, same theme-aware repaint logic. Different data source.
- Color and icon picker (shared with Categories).
- Avatar component with its light-mode contrast adjustments.
- AI assistant tool (`create_goal`).
- 7-goal demo seed.
- Recent fixes (chart morph survival, label collision, picker popup, etc.).

## Open questions

Conditional on the account-linked direction:

1. When a single account is linked to a single goal, should the default be "the whole balance counts" (simple, but ambiguous when the account is later shared), or require an explicit allocation amount upfront?
2. When goals total more than the linked savings (e.g. $30K of goals against $20K of savings), should the system hard-block, show a soft warning, or stay silent?
3. The stepper's current optional "starting contribution" step does not map to the new model. Options: replace it with an optional "earmark $X of <selected account> right now" step, or drop step 2's disclosure entirely.
4. Should the schema leave a forward-compatible hook (e.g. a nullable `transaction_id` on the contributions-replacement table) so tags can layer in later without a schema rewrite?

The PR is on hold until the model decision lands.
