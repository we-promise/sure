# Bond feature — follow-ups

Deferred work for the Bond Core feature (PR #4069). These were intentionally
kept out of the core PR to keep it reviewable; they are tracked here so they
are not lost.

## Positions / holdings tab

**Status:** deferred to a follow-up PR.

Bond lots are currently surfaced through the account **Activity** tab (the
"New activity → bond purchase" action and the activity feed). There is no
dedicated positions/holdings tab for bond accounts, unlike Investment accounts.

A follow-up should add a bond positions tab showing open lots (and a closed /
settled section) with per-lot name/subtype, current rate, holdings value
(`BondLot#estimated_current_value`), maturity, and total return.

Implementation notes (so the next person doesn't have to re-derive them):

- Wire the tab in `app/components/UI/account_page.rb`: add a `when "Bond"`
  branch to `#tabs` (e.g. `[:activity, :positions]`) and a matching branch in
  `#tab_content_for`.
- Add the view(s) under `app/views/bonds/tabs/` (mirror
  `app/views/investments/tabs/_holdings.html.erb`, which lazy-loads a
  turbo-frame backed by a controller — decide whether bonds need the same
  controller-backed index or can render lots directly).
- Restore the `bonds.tabs.positions` / `bonds.tabs.closed` locale keys in
  `config/locales/views/bonds/{en,pl}.yml` (removed in PR #4069 because no view
  rendered them; see git history for the previous content).
- Follow the design-system rules in `docs/llm-guides/design-system.md`
  (DS table primitives, functional tokens, the `icon` helper, `t()` strings).
- Add controller/view tests for the new tab.

## Coupon cash-flow accounting

**Status:** deferred to a follow-up PR.

Periodic coupons (monthly / quarterly / semi-annual / annual) are **retained in
the bond's value** as simple interest — `BondLot#estimated_current_value` keeps
each coupon's accrued interest in the lot's value through maturity, so holdings,
`total_return_amount`, and settlement are internally consistent and never drop a
paid coupon into a void.

What's *not* modeled yet: a coupon payment is not booked as its own cash ledger
entry on the coupon date. Economically the coupon is treated as retained within
the position rather than paid out to the account's cash. A follow-up should
record each coupon as a cash `Transaction` on its payment date (likely a
scheduled job, mirroring `SettleMaturedBondLotsJob`), with idempotency and
reconciliation against the settlement entry. If that lands, the retained-coupon
simple-interest model in `estimated_current_value` should move to not
double-count coupons that have been paid out to cash.

Only `at_maturity` coupons compound (reinvested); periodic coupons use simple
interest, which matches a non-reinvesting coupon bond.

## Accrued value and performance (shipped in #4069, noted for context)

- Bond holdings now reflect accrued value over the lot's life via
  `BondLot#estimated_current_value` (not flat principal).
- The accrual loops (`estimated_current_value`, `capitalization_history`) were
  made O(n) by advancing period indices incrementally. If a positions tab or
  per-lot detail view renders many long-dated lots per request, re-check
  whether additional memoization is warranted.
