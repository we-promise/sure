# Cash flow

`GET /api/v1/cash_flow?month=2024-02-01` accepts read or read_write authorization. The optional month must be a non-future ISO first day. Invalid dates return 422 `invalid_month`. Missing authorization returns 401.

The default month and `as_of` use the authenticated family's time zone. Current periods end today; historical periods include the whole month. Amounts are decimal strings in family currency. Savings rate is percentage points, may be negative, and is null without positive income.

The endpoint delegates to IncomeStatement, including the authenticated user's finance-account scope, excluded/report-ineligible accounts, posted transactions, budget-included kinds, and daily exchange rates. It preserves Sure's existing missing-exchange-rate fallback (unconverted 1:1); it does not promise complete FX coverage.

Both comparison series contain every day in chronological order with cumulative amounts. The previous series always includes the full previous month. For the current month, the comparison total uses the same elapsed day, clamped to the previous month's last day; historical months compare full months. Clients may fold the previous curve for chart layout but must not change its totals or reporting semantics.

The response is bounded to two months regardless of the amount of account history. Use transaction endpoints for drill-down; do not aggregate downloaded transaction pages to reproduce this summary.

This resource can grow to include server-calculated category flows for a Sankey chart. The current contract provides monthly totals and spending comparisons; it does not yet expose a nodes-and-links breakdown.
