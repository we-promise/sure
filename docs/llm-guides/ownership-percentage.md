# Ownership percentage

Each person's net worth counts only their share of an account. Stored balances
always stay at 100% of the account; the share is applied when reading.

## Calculation basis (read this before adding a balance-based feature)

An account now has two different amounts, and they are not interchangeable:

| Basis | What it is | Used by |
| --- | --- | --- |
| **Whole account** | `accounts.balance` and the `balances` rows, 100% of the account | Account pages and rows, `/api/v1/accounts` `balance`, `get_accounts`, `record_valuation`, transactions, cash flow, budgets, goals, investments, loans, insights |
| **Personal share** | The whole-account amount times the viewer's fraction | Net worth, dashboard group totals and sparklines, the net worth chart, `/api/v1/balance_sheet`, `get_balance_sheet` |
| **Family gross** | The whole-account amounts summed for the family, with no viewer | Family-wide insights and notifications |

Rules:

- **Every new balance-based feature declares its basis** in code (a comment is
  enough) and in any user-facing label. Do not mix the two in one figure.
- Personal totals cannot be added together to get a household total. Shares need
  not sum to 100, so two people can both count a whole account.
- Input is always the whole account. `record_valuation` and manual balance
  edits take the full account value; never enter a person's share, because it
  would be scaled a second time on read.
- A caller that passes no `user:` gets the whole account.

## Data model

- `accounts.ownership_percentage` is the **owner's** share.
- `account_shares.ownership_percentage` is each **co-owner's** share.
- Both are `decimal(5,2)`, default 100, not null, with check constraints for 0..100.
- Shares are not required to sum to 100, so two people can both hold 100 (the
  default) for a fully shared account.
- `Account#ownership_percentage_for(user)` resolves the share: the owner's column,
  the user's `AccountShare`, or 100 for anyone else or a nil user. Also see
  `ownership_fraction_for`, `owned_balance_for` and `owned_balance_money_for`.

## Behavior to know

- **History uses today's percentage.** The chart multiplies every historical
  balance by the viewer's current fraction. Changing 50% to 25% restates the whole
  line, including years before the change. Representing "I sold half my stake on a
  date" would need dated ownership records, which do not exist.
- **Removing an owner** (`User#reassign_owned_accounts!`): the new owner keeps the
  percentage they held as a co-owner. The departed owner's percentage is dropped,
  and an account the new owner had no share in starts at 100. The new owner is
  the first admin (otherwise the oldest member), not necessarily a co-owner of
  that account, so they and the remaining co-owners can together count more than
  100%; the owner can correct it in the sharing dialog.
- **Sharing starts at 100.** `Account#share_with!` and `auto_share_with_family!`
  create shares at the column default. Unsharing deletes the share, so resharing
  starts again at 100; the owner sets a percentage afterwards in the sharing dialog.
- **Export/import** carries the owner's percentage only (`all.ndjson` and the
  `ownership_percentage` column of `accounts.csv`). Co-owner shares are not
  exported or imported, so a restored family re-enters them. An export from before
  this feature imports at 100; a value outside 0..100 skips the account.

## Where the share is applied

- Dashboard / balance sheet: `BalanceSheet::AccountTotals#converted_balance_for`
  (`BalanceSheet#sorted` sorts by the scaled value).
- Net worth charts: `Balance::ChartSeriesBuilder` takes `user:` and multiplies each
  account by `viewer_fraction` in SQL. `BalanceSheet::NetWorthSeriesBuilder` and
  `NetWorthBreakdownSeriesBuilder` pass the user. Callers without `user:` (for
  example single-account charts) count accounts in full.
- Account group sparklines (`AccountableSparklinesController`) pass the viewer so
  the trend matches the group total. Their cache key digests the viewer's
  percentages. Per-account sparklines stay whole-account, like the row balance.
- Sidebar rows show a small `DS::Pill` with the viewer's percentage when it is
  below 100 (`AccountsHelper#ownership_badge_label`); the row balance stays whole.
  The sidebar fragment cache version (`account_sidebar_tabs_v4`) must be bumped
  when that template changes.
- Chart caches key on `accounts.updated_at` (owner column) and on the viewer's
  `AccountShare.updated_at` (co-owner column).
- API: `api/v1/accounts` returns `ownership_percentage`, `owned_balance` and
  `owned_balance_cents` for the authenticated user. `balance` stays the full value.
  `/api/v1/balance_sheet` inherits the scaling through `BalanceSheet`, so its
  totals change meaning for users with percentages below 100; clients that sum
  `/accounts` balances themselves will not match it.
- Assistant / MCP: `get_balance_sheet` (current totals and history) is
  share-weighted; `get_accounts` returns whole-account balances. The tool
  descriptions state this.

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
  `UI.account.chart.ownership_share`, `accounts.sidebar.ownership_share`).

## Out of scope (future enhancements)

These stay on the **whole-account** basis until each gets its own decision:

- Transactions, the income statement, cash flow and spending.
- Investment statement, gains and holdings views, goals, paycheck planning,
  budgets and loan projections. An account percentage cannot say who earned a
  salary, paid a bill or committed money to a goal.
- Insights and notifications: generated once per family from whole-account
  balances, so a net worth milestone can differ from a co-owner's own dashboard.
- Per-account `get_accounts` ownership fields, and system prompt guidance.
- Dated ownership records (history that does not restate).
- Co-owner `account_shares` in export/import.
- Flutter app (`mobile/`): it reads `/api/v1/balance_sheet` (now share-weighted)
  and `/api/v1/accounts` (whole-account `balance`, new fields ignored) and shows no
  share. Needs a product decision before it displays one. Any Swift client is not
  covered either.
- The accounts index (`/accounts`) rows, which show whole-account balances.
- Optional validation or warning when shares sum to more than 100.
- Translations for non-English locales.
