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
The form's "availability" select writes `liquidity_choice`: a level locks
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

## Transfers that count as saving

A transfer from available money into a depository account that is not
available on the booking date (`locked` before its release date, or
`long_term`) is a saving, like a contribution to a brokerage account. Its
outflow leg gets the existing kind `investment_contribution` and the family's
`investment_contributions_category` ("Investment Contributions"), so
budgets show it as money set aside. Rules:

- The decision lives in `Transfer.kind_for_account(destination, source:, date:)`
  and `Transfer.saving_into?`. Every path that creates or matches a transfer
  passes the source account and the booking date: `Transfer::Creator`, the
  automatic matcher, the manual match dialog, the "set as transfer" rule
  action and the Sure data import.
- Money moved between two savings accounts (brokerage, crypto, locked or
  long-term bank accounts) is not new saving and stays `funds_movement`, in
  both directions: a locked deposit moved into a brokerage account is not a
  new contribution either.
- Borrowed money (a loan or credit card as the source) is not saving.
- Property, vehicles and other assets stay out even though they are
  long-term: a down payment or money lent to a friend is not saving.
- Money coming back (a matured term deposit paid out to the current account)
  stays `funds_movement`; it is not income.
- Instant-access savings (`immediate`) stay neutral. A user who wants them to
  count as saving classifies the account as locked.
- The kind is stored per transaction, so this applies to everyone, without the
  preview switch, and only to transfers created or matched from now on. Old
  transfers are not reclassified.
- The savings rate insight adds `IncomeStatement#savings_contributions_total`
  back to income minus expenses, so saving does not lower the savings rate.

## Release reminders

`Account::ReleaseReminder` decides which locked accounts need a reminder on a
day: `upcoming` (released within the lead time), `released` (on the release
date and for a week after) and `renewal` (a renewing deposit; from the lead
time before the renewal date until that day). Both channels ask it, so they
never disagree:

- Feed: `Insight::Generators::AccountReleaseGenerator`, run by
  `GenerateInsightsJob`. The feed is per family, so it runs only when a member
  chose the feed, takes the longest lead time among them and only accounts
  that count in one of their finances.
- E-mail: `AccountReleaseNotificationJob` (daily cron) mails each member who
  chose e-mail a digest (`AccountAvailabilityMailer`) for the accounts in their
  own finances with their own lead time. `AccountReleaseNotice` stores what was
  sent so nothing goes out twice.

Channel and lead time are per person in `users.preferences`
(`User#account_release_channel`, `#account_release_lead_days`), set on the
Preferences page.

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

## Preview gating

The columns, migration backfill and defaults apply to everyone. Behavior and
UI are behind the preview switch, except the saving rule above: the form
section, header badge, Details tab, the budget's and paycheck planner's switch
from "depository" to `immediate_assets_on`, the dashboard widget and the
reports section read the viewer's `preview_features_enabled?`. Insights
already run only for preview families; release reminders, their settings and
the e-mail only reach members with preview features on. API and assistant
fields are always
returned (additive).
