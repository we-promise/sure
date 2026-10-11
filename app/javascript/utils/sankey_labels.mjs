// Label-collision rule for the new preview Sankey chart.
// Nodes compete for labels only within their own
// visual column: d3-sankey's justify alignment can place same-depth nodes
// in different columns (sinks flush right), so columns are keyed by x0,
// not depth. Within a column, labels are considered in descending
// node-value order and kept only when they clear the minimum spacing from
// every label already kept. A small node can no longer hide a large
// category's label merely by sitting above it: the prominent node is
// labeled first, and the small neighbor is the one that yields.
export function hiddenSankeyLabels(nodes, { height, minSpacing }) {
  const hiddenLabels = new Set();
  const isLargeGraph = height > 600;
  const spacing = isLargeGraph ? minSpacing * 0.7 : minSpacing;

  // Group nodes by visual column (x position assigned by d3-sankey)
  const columns = new Map();
  nodes.forEach((node) => {
    const column = Math.round(node.x0);
    if (!columns.has(column)) columns.set(column, []);
    columns.get(column).push(node);
  });

  columns.forEach((columnNodes) => {
    // Most significant nodes claim their labels first; ties fall back to
    // vertical position so the rule stays deterministic.
    const byProminence = [...columnNodes].sort((a, b) => {
      if (b.value !== a.value) return b.value - a.value;
      return (a.y0 + a.y1) / 2 - (b.y0 + b.y1) / 2;
    });

    const keptYs = [];

    byProminence.forEach((node) => {
      const nodeY = (node.y0 + node.y1) / 2;
      const nodeHeight = node.y1 - node.y0;

      // Tall bars in large graphs always earn their label.
      if (
        (isLargeGraph && nodeHeight > spacing * 1.5) ||
        keptYs.every((keptY) => Math.abs(nodeY - keptY) >= spacing)
      ) {
        keptYs.push(nodeY);
      } else {
        hiddenLabels.add(node.index);
      }
    });
  });

  return hiddenLabels;
}
