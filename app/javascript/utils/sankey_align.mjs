// Label side for the cash flow Sankey charts. (Column assignment is
// d3-sankey's sankeyCenter: a sink at its depth, a source one column before
// the nearest node it feeds, so a category without subcategories stays in
// the category column and the surplus and invested outflows end beside Cash
// Flow instead of flush right across the categories.)
//
// Labels face the middle of the chart so neither edge cuts them off. The
// surplus and invested outflows are the exception: beside Cash Flow, a
// label facing the middle shares the gap with the Cash Flow label and
// loses to it under the overlap rule, so theirs goes on the right, where
// nothing flows out of them, unless that is the chart's edge.
const OUTFLOW_IDS = new Set(["surplus_node", "invested_node"]);

export function sankeyLabelOnRight(nodes, width) {
  const lastColumn = Math.max(...nodes.map((node) => node.layer));
  return (node) =>
    (OUTFLOW_IDS.has(node.id) && node.layer < lastColumn) ||
    node.x0 < width / 2;
}
