# Investment contributions, income and budgets

Investment contributions move money into an investment account. They are not
consumption, but they still use an investment budget allocation and reduce the
cash available outside the investment account.

## Reporting contract

- Dashboard and Reports expenses, spending trends and savings rates exclude
  transactions classified as investment contributions.
- Budgets continue to count those transactions in actual allocation usage,
  suggested budgets, category averages/medians and rollover. Historical cash
  outflows are combined **per period before** calculating their median.
- Cash-availability warnings retain investment outflows in their spending
  baseline. Reserve goals based on months of expenses use consumption, so an
  existing goal's calculated target can fall when it next refreshes.
- Reports, CSV and print show gross investment contributions separately. This
  is not net contributions, investment returns, or the provider-side Investment
  Flows report. Withdrawals do not subtract from this gross figure.
- Both Sankey charts show an Invested outflow. Surplus/Deficit describes cash
  remaining after investing; `net_savings` remains income minus consumption.
  Investing from prior savings can therefore produce a cash-flow deficit without
  increasing consumption.
- A matched transfer counts at most once, on its budget-tracked outflow. This
  remains true if old provider data stamped both legs as contributions or loan
  payments. Selecting only the destination account does not turn an internal
  transfer into new income.
- Loan payments still count as spending; this does not infer a principal/interest
  split. Transfer relationship filtering prevents counting both matched legs.

## Correcting a paycheck deposited into a brokerage account

Open the unmatched deposit's transaction drawer, expand **Settings**, and choose
**Treat as income**.
The action is available to an account owner or someone with full control, for
unmatched inflows in non-tax-advantaged investment/crypto accounts. It is not
available on matched pairs or split transactions.

This clears the transfer/contribution activity classification, changes the
transaction to a regular transaction, and uses the existing user-modified and
attribute-lock mechanisms to preserve the correction during sync. Automatic
transfer detection also respects the locked regular-transaction kind. The amount,
account, provider identity and selected category do not change. After correcting,
choose the appropriate income category if needed.

Assigning a category alone does not establish that a deposit is outside income.
Sure must not guess whether an ambiguous provider transfer represents a paycheck
or movement between the user's own accounts. Explicit rules/manual matching can
still change classification; this protection applies to provider sync and
background automatic matching.

## Client compatibility

The public cash-flow envelopes include `investment_contributions` as a decimal
string. Sankey data includes an `invested` decimal and the structural node kind
`invested`; clients with exhaustive node-kind handling must accept it. Assistant
income statements expose `invested.total`, including account-filtered requests.

For identical historical data, `spending`, `net_savings`, and `savings_rate` can
change. These are intentional accounting changes, not merely additive fields.
No data migration or new household preference is required. Existing categories
are not renamed or backfilled. Report caches are versioned for the new semantics
and include transfer relationship freshness.

## Consolidation scope

This implementation builds on #3609's reporting/budget separation, #3461's
transfer relationship and re-sync fixes, and #3952's Invested visualization and
assistant totals. It intentionally does not carry either competing household
setting: removing consumption must not erase investment budget usage.

The category-identity migration and broader category/drilldown work in #3461 are
independent and are not superseded here. Its original PR must not be closed as
fully replaced without preserving or explicitly deferring those changes. The
optional reporting preference from #3952 likewise remains a separate product
choice. Existing FX conversion policy and investment-withdrawal accounting are
not changed by this consolidation.
