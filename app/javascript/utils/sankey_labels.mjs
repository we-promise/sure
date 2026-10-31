// Label placement shared by the dashboard's Sankey charts.
// Nodes compete for labels only within their own
// visual column: d3-sankey's justify alignment can place same-depth nodes
// in different columns (sinks flush right), so columns are keyed by x0,
// not depth. Within a column, labels are considered in descending
// node-value order, and a placed label never moves again: the largest labels
// sit at their bars' centres, and a smaller one may only slide into the free
// space left between its neighbours, as long as it still touches its own
// bar. It is hidden when no such space is left. A node that runs out of room
// still holds its slot, so a smaller neighbour can't be labeled in its place
// and the visible labels stay the largest ones.
//
// On a narrow chart a label can also run across the gap into the next
// column. When the caller passes each label's measured box (keyed by
// node.index, measured at the bar's centre), a label yields if it would
// cover another node's bar, or a more prominent label from another column.
//
// Returns the hidden node indexes and, for every shown label, the y of its
// centre.
export function layoutSankeyLabels(nodes, { height, minSpacing, labelBoxes }) {
  const hidden = new Set();
  const labelY = new Map();
  const isLargeGraph = height > 600;
  const spacing = isLargeGraph ? minSpacing * 0.7 : minSpacing;
  const bars = labelBoxes ? nodes.map(barBox) : [];
  const placedByColumn = new Map();
  const crowdedYsByColumn = new Map();

  const shiftedBox = (node, y) => {
    const box = labelBoxes?.get(node.index);
    return box && { ...box, y: box.y + y - centre(node) };
  };

  const isClear = (node, y, column) => {
    const box = shiftedBox(node, y);
    if (!box) return true;
    if (bars.some((bar) => bar.node !== node && overlaps(box, bar))) {
      return false;
    }
    // Same-column spacing is the placement rule's job.
    for (const [otherColumn, placed] of placedByColumn) {
      if (otherColumn === column) continue;
      for (const other of placed) {
        const otherBox = shiftedBox(other, labelY.get(other.index));
        if (otherBox && overlaps(box, otherBox)) return false;
      }
    }
    return true;
  };

  // One pass in prominence order, so a label rejected for crossing into
  // another column never blocks a smaller neighbour that would fit.
  [...nodes].sort(byProminence).forEach((node) => {
    // Columns are the visual x position assigned by d3-sankey
    const column = Math.round(node.x0);
    const placed = placedByColumn.get(column) || [];
    const crowdedYs = crowdedYsByColumn.get(column) || [];
    const crowded = crowdedYs.some(
      (crowdedY) => Math.abs(centre(node) - crowdedY) < spacing,
    );
    const y = crowded
      ? null
      : freeSlot(node, placed, labelY, { spacing, height });

    if (y === null) {
      crowdedYsByColumn.set(column, [...crowdedYs, centre(node)]);
      hidden.add(node.index);
    } else if (isClear(node, y, column)) {
      placedByColumn.set(column, [...placed, node]);
      labelY.set(node.index, y);
    } else {
      hidden.add(node.index);
    }
  });

  return { hidden, labelY };
}

// The y closest to the node's bar centre where its label clears the labels
// already placed in its column (keeping their top-to-bottom order), still
// touches its own bar and stays inside the chart; null when there is none.
function freeSlot(node, placed, labelY, { spacing, height }) {
  const half = spacing / 2;
  const y = centre(node);
  let lo = Math.min(Math.max(node.y0 - half, half), y);
  let hi = Math.max(Math.min(node.y1 + half, height - half), y);

  placed.forEach((other) => {
    if (byCentre(other, node) < 0) {
      lo = Math.max(lo, labelY.get(other.index) + spacing);
    } else {
      hi = Math.min(hi, labelY.get(other.index) - spacing);
    }
  });

  return lo > hi ? null : Math.min(Math.max(y, lo), hi);
}

// Most significant nodes claim their labels first; ties fall back to
// vertical position so the rule stays deterministic.
function byProminence(a, b) {
  if (b.value !== a.value) return b.value - a.value;
  return centre(a) - centre(b);
}

function byCentre(a, b) {
  return centre(a) - centre(b) || a.index - b.index;
}

function centre(node) {
  return (node.y0 + node.y1) / 2;
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

function barBox(node) {
  return {
    node,
    x: node.x0,
    y: node.y0,
    width: node.x1 - node.x0,
    height: node.y1 - node.y0,
  };
}
