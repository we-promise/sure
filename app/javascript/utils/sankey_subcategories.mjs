import { sankeyLinkIndex } from "utils/sankey_zoom";

// Node ids carry the hierarchy the server built (PagesController
// #build_cashflow_sankey_data): "<side>_<category id>" for a category and
// "<side>_sub_<category id>" for a subcategory under it. A subcategory whose
// net direction runs against its parent is linked straight to Cash Flow
// instead; it is a column of its own and is kept.
const CASH_FLOW_NODE_ID = "cash_flow_node";

// The chart without its subcategory column. A category's value already
// includes its subcategories, so dropping them changes no total; it frees a
// column, which on a narrow chart is the difference between labels that fit
// and labels that are hidden.
export function withoutSankeySubcategories(data) {
  const nodes = data?.nodes || [];
  const links = data?.links || [];
  const cashFlowIndex = nodes.findIndex((node) => node.id === CASH_FLOW_NODE_ID);
  if (cashFlowIndex < 0) return data;

  const linkedToCashFlow = new Set();
  links.forEach((link) => {
    const source = sankeyLinkIndex(link.source);
    const target = sankeyLinkIndex(link.target);
    if (source === cashFlowIndex) linkedToCashFlow.add(target);
    if (target === cashFlowIndex) linkedToCashFlow.add(source);
  });

  const kept = nodes
    .map((_, index) => index)
    .filter(
      (index) =>
        !String(nodes[index].id).includes("_sub_") || linkedToCashFlow.has(index),
    );
  if (kept.length === nodes.length) return data;

  const reindexed = new Map(kept.map((index, newIndex) => [index, newIndex]));

  return {
    ...data,
    nodes: kept.map((index) => ({ ...nodes[index] })),
    links: links
      .filter(
        (link) =>
          reindexed.has(sankeyLinkIndex(link.source)) &&
          reindexed.has(sankeyLinkIndex(link.target)),
      )
      .map((link) => ({
        ...link,
        source: reindexed.get(sankeyLinkIndex(link.source)),
        target: reindexed.get(sankeyLinkIndex(link.target)),
      })),
  };
}
