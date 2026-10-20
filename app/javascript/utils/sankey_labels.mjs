// Label-collision rule shared by the dashboard's Sankey charts.
// Nodes compete for labels only within their own
// visual column: d3-sankey's justify alignment can place same-depth nodes
// in different columns (sinks flush right), so columns are keyed by x0,
// not depth. Within a column, labels are considered in descending
// node-value order and kept only when they clear the minimum spacing from
// every label already kept. A small node can no longer hide a large
// category's label merely by sitting above it: the prominent node is
// labeled first, and the small neighbor is the one that yields.
//
// On a narrow chart a label can also run across the gap into the next
// column. When the caller passes each label's measured box (keyed by
// node.index), a label yields if it would cover another node's bar, or a
// more prominent label from another column.
export function hiddenSankeyLabels(nodes, { height, minSpacing, labelBoxes }) {
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
    const keptYs = [];

    [...columnNodes].sort(byProminence).forEach((node) => {
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

  if (labelBoxes) hideLabelsCrossingColumns(nodes, labelBoxes, hiddenLabels);

  return hiddenLabels;
}

// Most significant nodes claim their labels first; ties fall back to
// vertical position so the rule stays deterministic.
function byProminence(a, b) {
  if (b.value !== a.value) return b.value - a.value;
  return (a.y0 + a.y1) / 2 - (b.y0 + b.y1) / 2;
}

const CLEARANCE = 2;

function overlaps(a, b) {
  return (
    a.x < b.x + b.width + CLEARANCE &&
    b.x < a.x + a.width + CLEARANCE &&
    a.y < b.y + b.height + CLEARANCE &&
    b.y < a.y + a.height + CLEARANCE
  );
}

function hideLabelsCrossingColumns(nodes, labelBoxes, hiddenLabels) {
  const bars = nodes.map((node) => ({
    node,
    x: node.x0,
    y: node.y0,
    width: node.x1 - node.x0,
    height: node.y1 - node.y0,
  }));
  const kept = [];

  [...nodes].sort(byProminence).forEach((node) => {
    const box = labelBoxes.get(node.index);
    if (!box || hiddenLabels.has(node.index)) return;

    // Same-column spacing is the rule above's job.
    const column = Math.round(node.x0);
    const coversBar = bars.some((bar) => bar.node !== node && overlaps(box, bar));
    const coversLabel = kept.some(
      (other) => other.column !== column && overlaps(box, other.box),
    );

    if (coversBar || coversLabel) {
      hiddenLabels.add(node.index);
    } else {
      kept.push({ column, box });
    }
  });
}
