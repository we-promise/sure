# Ownership percentage

Each person's net worth counts only their share of an account. Stored balances
always stay at 100% of the account; the share is applied when reading.

## Data model

- `accounts.ownership_percentage` is the **owner's** share.
- `account_shares.ownership_percentage` is each **co-owner's** share.
- Both are `decimal(5,2)`, default 100, not null, with check constraints for 0..100.
- Shares are not required to sum to 100, so two people can both hold 100 (the
  default) for a fully shared account.
- `Account#ownership_percentage_for(user)` resolves the share: the owner's column,
  the user's `AccountShare`, or 100 for anyone else or a nil user. Also see
  `ownership_fraction_for`, `owned_balance_for` and `owned_balance_money_for`.

## Where the share is applied

- Dashboard / balance sheet: `BalanceSheet::AccountTotals#converted_balance_for`
  (`BalanceSheet#sorted` sorts by the scaled value).
- Net worth charts: `Balance::ChartSeriesBuilder` takes `user:` and multiplies each
  account by `viewer_fraction` in SQL. `BalanceSheet::NetWorthSeriesBuilder` and
  `NetWorthBreakdownSeriesBuilder` pass the user. Callers without `user:` (for
  example single-account charts) count accounts in full.
- Chart caches already key on `accounts.updated_at` (owner column) and on the
  viewer's `AccountShare.updated_at` (co-owner column).
- API: `api/v1/accounts` returns `ownership_percentage`, `owned_balance` and
  `owned_balance_cents` for the authenticated user. `balance` stays the full value.
  `/api/v1/balance_sheet` inherits the scaling through `BalanceSheet`.

## Permissions

Only the account owner sets percentages (their own and co-owners'), in
`AccountSharingsController#update`. A shared user sees their own share as read-only text.

## Placeholder UI to polish

The UI is functional but unstyled on purpose:
- `app/views/account_sharings/show.html.erb`: owner field, per-member ownership column,
  read-only share text for co-owners.
- `app/components/UI/account/chart.html.erb` (`ownership_share_display`): "Your share"
  line on the account page.
- Locale keys currently exist only in `en.yml` (`account_sharings.show.*`,
  `UI.account.chart.ownership_share`).

## Out of scope (future enhancements)

- Scale transactions, the income statement and spending by ownership share.
- Investment statement, gains/holdings views, goals, insights and assistant tools.
- Per-row balances on the dashboard list still show the full balance; group totals
  and net worth are scaled.
- Account CSV export and export/import of `account_shares` (NDJSON export includes the
  owner column via `as_json`; `Family::DataImporter` not verified).
- Optional validation or warning when shares sum to more than 100.
- Translations for non-English locales.
