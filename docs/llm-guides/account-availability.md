# Account availability

Every account carries an availability level ("liquidity") that says how quickly
its money can be reached. Use it whenever code needs to know whether money is
available. Do not hardcode `accountable_type: "Depository"` for that question:
a term deposit is a depository account and is not available, a brokerage
account is not a depository account and can be sold within days.

## Levels

Stored on `accounts.liquidity`:

| Level | Meaning | Typical subtypes |
| --- | --- | --- |
| `immediate` | Reachable today | checking, cash, savings, credit card, line of credit |
| `short_term` | Reachable within days, possibly with price risk or notice | brokerage, crypto, money market, notice savings |
| `locked` | Locked until `accounts.available_on` | CD, building savings, VL, Indian FD/RD/NSC/KVP |
| `long_term` | Locked for years | retirement wrappers, HSA, property, vehicles, loans |

`available_on` is the release date of a locked account. With `auto_renew` and
`renewal_term_months` the deposit rolls over and never releases by itself.

## Where the logic lives

- `Account::Liquidity` (concern on `Account`): validations, the callback that
  writes the default, predicates and scopes.
- `Accountable.rules_for(subtype)` returns `Accountable::Rules`, the rule set a
  subtype brings: default liquidity and tax treatment. Each accountable class
  overrides `default_liquidity_for(subtype)` (and `default_tax_treatment_for`
  where it has one). Add a new subtype there, not in a new constant elsewhere.
- `Account::RuleDetails` lists the rules for the account page's "Details" tab,
  with where each value comes from.

## Defaults and manual choices

New accounts, and accounts whose subtype changes, take the subtype default.
The form's "availability" select writes `liquidity_choice` (the Sure data
import sets it from an exported lock): a level locks
`liquidity` in `locked_attributes`, so later subtype changes and provider syncs
leave it alone; `automatic` unlocks it and restores the default. Provider code
that changes `accountable.subtype` directly is covered by a callback on the
accountable.

`liquidity` is excluded from `lock_saved_attributes!`: the default written on
create must not look like a user choice.

## Asking the question

Pass the date you are asking about; release dates are evaluated per day, which
keeps historical figures right (today's level, applied with each day's date).
"Today" comes from `Account.liquidity_today_for(family)`, which uses the
family's time zone rather than the server's.

```ruby
today = Account.liquidity_today_for(family)

family.accounts.visible.available_assets_on(today)  # wealth you can reach at short notice
family.accounts.visible.immediate_assets_on(today)  # money for this month's budget
family.accounts.visible.bound_assets_on(today)      # the rest of the assets
family.accounts.visible.short_term_liabilities      # credit cards, overdraft lines

account.available_on?(today)
account.effective_liquidity(today)  # a released locked account reads "immediate"
account.next_release_date(today)
```

Assets and liabilities are separate scopes on purpose: a combined scope would
count credit cards as available wealth.

## Overview figures

`BalanceSheet#liquidity(date:)` returns a `BalanceSheet::LiquidityOverview`
built from the balance sheet's account rows (same accounts, same converted
balances as net worth): available and locked assets, short-term liabilities,
available net worth, assets per level, the release timeline buckets and the
list of upcoming releases. `BalanceSheet#available_net_worth_series` is the
history of available net worth; a locked account enters it on its release
date (`Balance::ChartSeriesBuilder`'s `account_active_from_dates`).

The dashboard widget (`pages/dashboard/_liquidity`), the reports section
(`reports/_liquidity`), `GET /api/v1/balance_sheet` (`availability`) and the
assistant's `get_balance_sheet` all read these two methods; shared view
partials live in `app/views/liquidity/`.

Budget, paycheck planner, idle-cash and cash-flow insights and goals with a
reserve ask `immediate_assets_on` instead of "every depository account". The
savings rate insight adds `IncomeStatement#savings_contributions_total`
(outflows of kind `investment_contribution`) back to income minus expenses,
so saving does not lower the savings rate.

## Preview gating

The columns, the migration backfill and the defaults apply to everyone; they
change no figure on their own. Code that answers "is this money available?"
with the scopes above must read the viewer's `preview_features_enabled?` until
the feature is released. The form section, the header badge, the Details tab,
the budget's and paycheck planner's switch from "depository" to
`immediate_assets_on`, the dashboard widget and the reports section already
do. Insights run only for preview families. API and assistant fields are
always returned (additive).
