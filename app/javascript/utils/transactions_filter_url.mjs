// Category nodes in the cashflow Sankey have ids prefixed income_/expense_
// (incl. *_sub_). Structural nodes (cash_flow_node, surplus_node) are not
// categories and must not deep-link to transactions.
export function isNavigableCategoryNode(id) {
  return /^(income|expense)_/.test(id);
}

// Builds a relative deep link to the transactions index, filtered by a single
// category and (optionally) a start/end date range, account ids and statuses.
// Mirrors the params the transactions search form submits: q[categories][],
// q[start_date], q[end_date], q[account_ids][], q[status][].
//
// filterValue must be the category's stable filter value (Category#filter_value:
// the persisted name for a real category, or Category::UNCATEGORIZED_FILTER_VALUE
// for the synthetic "Uncategorized" node/segment) -- not the display name, since
// the transactions search filter no longer matches the localized "Uncategorized"
// label.
export function buildCategoryTransactionsUrl({
  filterValue,
  startDate,
  endDate,
  accountIds = [],
  statuses = [],
  basePath = "/transactions",
}) {
  const params = new URLSearchParams();
  params.append("q[categories][]", filterValue);
  if (startDate) params.append("q[start_date]", startDate);
  if (endDate) params.append("q[end_date]", endDate);
  for (const id of accountIds) params.append("q[account_ids][]", id);
  for (const status of statuses) params.append("q[status][]", status);
  return `${basePath}?${params.toString()}`;
}
