// Category nodes in the cashflow Sankey have ids prefixed income_/expense_
// (incl. *_sub_). Structural nodes (cash_flow_node, surplus_node) are not
// categories and must not deep-link to transactions.
export function isNavigableCategoryNode(id) {
  return /^(income|expense)_/.test(id);
}

// Builds a relative deep link to the transactions index, filtered by a single
// category name and (optionally) a start/end date range. Mirrors the params
// the transactions search form submits: q[categories][], q[start_date],
// q[end_date].
export function buildCategoryTransactionsUrl({
  name,
  startDate,
  endDate,
  basePath = "/transactions",
}) {
  const params = new URLSearchParams();
  params.append("q[categories][]", name);
  if (startDate) params.append("q[start_date]", startDate);
  if (endDate) params.append("q[end_date]", endDate);
  return `${basePath}?${params.toString()}`;
}
