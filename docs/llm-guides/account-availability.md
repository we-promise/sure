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

## Defaults and manual choices

New accounts, and accounts whose subtype changes, take the subtype default.
A manual choice arrives as `liquidity_choice` (the Sure data import sets it
from an exported lock): a level locks
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
  preview switch, to transfers created or matched from now on. Older transfers
  keep their kind until `rake data_migration:reconcile_savings_transfer_kinds`
  (`Transfer::SavingsKindReconciler`) and
  `rake data_migration:reconcile_investment_transfer_kinds` run; both take
  `DRY_RUN=1` and `FAMILY_ID=`. The same holds when a user later changes an
  account's availability or release date: stored kinds stay until the tasks
  run again.
- `InvestmentFlowStatement` follows the same rule: a matched brokerage
  contribution or withdrawal whose counterpart is a bank account locked or
  long-term on the booking date is not counted.

## Preview gating

The columns, the migration backfill and the defaults apply to everyone; they
change no figure on their own. Code that answers "is this money available?"
with the scopes above must read the viewer's `preview_features_enabled?` until
the feature is released. The one exception is the saving rule for
transfers above, which is stored per transaction. The API account fields (`liquidity`, `available_on`,
`available_now`) are always returned (additive).
