# Goals: how the balance is computed

*Posted 2026-05-12. Tied to PR [#1757](https://github.com/we-promise/sure/pull/1757) on branch `feat/savings-goals`.*

A Goal is a target. The number on its page is the live balance of the savings accounts you link to it, minus what other goals have claimed from those same accounts.

That's it. No "log a contribution" step. No parallel ledger.

## What this looks like in practice

You make a goal called House, target $50K. You link your Ally savings ($13K). The goal shows $13K, 26% to target.

Two months later, your Ally savings has grown to $15K because you've been saving. The goal shows $15K, 30%. You did nothing in the app for that to happen.

Three months later, you transfer $3K out for a car repair. The goal shows $12K. If you were on track before, the projection chart now reflects the setback.

## When one account funds two goals

If you also want a Vacation goal funded from Ally, you'll be asked to split it. "Of Ally's $15K, how much for House, how much for Vacation?" Two sliders, or a list if you have three or more goals on the same account.

The split is stored as a dollar allocation per goal per account.

## When the math doesn't work out

If your allocations exceed your balance (House $10K, Vacation $6K, but Ally holds $13K), Sure shows two numbers per goal: "Allocated $10K · Backed by $8.13K." You see the gap and decide what to do: reduce, top up, or accept it.

The split when over-allocated is pro-rata to allocation. No priority ordering in v1.

## What you give up

The act of logging a contribution. If that was the part of the feature you used, this model removes it. The replacement is watching your account grow.

## What you gain

The goal balance can't be a fiction. Spend from your savings, it shrinks. Save more, it grows. The system keeps you honest by construction.

## What stays

Status pills, projection chart, color and icon picker, AI assistant tool, demo data, every fix from the last week of work. The only thing changing is how the balance gets computed.

## What's deferred and why

Priority ordering for the over-allocation split. Pro-rata is fair-share; priority would let users say "House first." A real feature, not in v1.

Tag-based contribution annotation (Juanjo's Discord proposal). Annotations on real transactions can layer on later without changing the model.

Auto-fund from budget surplus. Was in the closed PR #1569. Belongs in a Budgets-aware follow-up.

## Still being decided

The pace calculation window. 90-day rolling average is the proposal, with a 30-day minimum for short-history accounts.

The split-prompt UX for the second-goal-on-an-account case. Slider vs. inputs, default proportions.

Whether manual accounts should carry any "this is a goal-only ledger" treatment, or just behave like any other account.

Open for feedback. The PR is on hold until the model is settled. Engineering mechanics in the [companion mechanics doc](goals-architecture-mechanics.md).
