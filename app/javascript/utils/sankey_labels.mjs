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
export function layoutSankeyLabels(
  nodes,
  { height, minSpacing: spacing, labelBoxes },
) {
  const hidden = new Set();
  const labelY = new Map();
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
      (crowdedY) => Math.abs(centre(node) - crowdedY) < spacing - TOLERANCE,
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

// Nodes in the most crowded column of a laid-out chart.
export function largestSankeyColumn(nodes) {
  const sizes = new Map();
  nodes.forEach((node) => {
    const column = Math.round(node.x0);
    sizes.set(column, (sizes.get(column) || 0) + 1);
  });
  return Math.max(0, ...sizes.values());
}

// Widens the gaps in every column that has height to spare, so each node's
// label can sit beside its bar. Nodes keep their order and move as little as
// possible in total, so a crowded group opens up both ways; bars keep their
// size. A column short of room spreads as far as it can, and its smallest
// labels yield as usual. Nodes never move onto a link that passes through
// their column (say Cash Flow to Surplus across the categories), so those
// columns are spread last, once the links' ends have settled. `relink`
// restacks and repositions the links after nodes move. Moves the nodes'
// y0/y1 in place.
export function spreadSankeyColumns(
  { nodes, links },
  { top, bottom, padding, minSpacing, relink },
) {
  const columns = new Map();
  nodes.forEach((node) => {
    const column = Math.round(node.x0);
    columns.set(column, [...(columns.get(column) || []), node]);
  });
  const crossed = (column) =>
    links.some(
      (link) => link.source.x1 < column[0].x0 && link.target.x0 > column[0].x1,
    );
  const options = { padding, minSpacing };

  [false, true].forEach((passedThrough) => {
    columns.forEach((column) => {
      if (crossed(column) !== passedThrough) return;

      column.sort((a, b) => a.y0 - b.y0);
      const gaps = freeRanges(column[0], links, { top, bottom, padding });
      // Each node stays in the free range nearest its bar.
      const groups = gaps.map(() => []);
      column.forEach((node) => {
        const centre = (node.y0 + node.y1) / 2;
        const distance = ([lo, hi]) =>
          centre < lo ? lo - centre : centre > hi ? centre - hi : 0;
        let nearest = 0;
        gaps.forEach((gap, i) => {
          if (distance(gap) < distance(gaps[nearest])) nearest = i;
        });
        groups[nearest].push(node);
      });
      groups.forEach((group, i) => {
        if (group.length) spreadWithin(group, gaps[i], options);
      });
    });
    relink?.();
  });
}

// Parts of a column's height (between top and bottom) that no passing link
// covers, as [lo, hi] ranges.
function freeRanges(node, links, { top, bottom, padding }) {
  const covered = links
    .filter((link) => link.source.x1 < node.x0 && link.target.x0 > node.x1)
    .map((link) => {
      const ys = [node.x0, node.x1].map((x) => linkCentreAt(link, x));
      const half = Math.max(1, link.width) / 2 + padding;
      return [Math.min(...ys) - half, Math.max(...ys) + half];
    })
    .sort((a, b) => a[0] - b[0]);

  const ranges = [];
  let from = top;
  covered.forEach(([lo, hi]) => {
    if (lo > from) ranges.push([from, Math.min(lo, bottom)]);
    from = Math.max(from, hi);
  });
  if (from < bottom) ranges.push([from, bottom]);
  return ranges.length ? ranges : [[top, bottom]];
}

// The y of a link's centre line at x, on the same curve d3.linkHorizontal
// draws: a cubic Bézier with both control points halfway across.
function linkCentreAt(link, x) {
  const x0 = link.source.x1;
  const x1 = link.target.x0;
  const across = (x - x0) / (x1 - x0);
  // x(t) = x0 + (x1 - x0) * (1.5t(1 - t) + t^3) rises steadily; bisect it.
  let lo = 0;
  let hi = 1;
  for (let i = 0; i < 30; i++) {
    const t = (lo + hi) / 2;
    if (1.5 * t * (1 - t) + t ** 3 < across) lo = t;
    else hi = t;
  }
  const t = (lo + hi) / 2;
  return link.y0 + (link.y1 - link.y0) * (3 * t ** 2 - 2 * t ** 3);
}

// Spreads one run of nodes (sorted top to bottom) inside [lo, hi]. When
// not every label fits, the largest nodes get label room first, and the
// first one that doesn't fit stops the handout, so a smaller node never gets
// a label a larger one couldn't; the rest pack at the padding.
function spreadWithin(group, [lo, hi], { padding, minSpacing }) {
  const heights = group.map((node) => node.y1 - node.y0);
  const last = group.length - 1;
  const room = hi - lo - heights[last];

  // Each node's top relative to the first node's top: bars and padding in
  // between, and labelled nodes' centres `minSpacing` from the previous one.
  const offsetsFor = (labelled) => {
    const offsets = [0];
    let previous = labelled.has(0) ? 0 : null;
    for (let i = 1; i <= last; i++) {
      let offset = offsets[i - 1] + heights[i - 1] + padding;
      if (labelled.has(i)) {
        if (previous !== null) {
          offset = Math.max(
            offset,
            offsets[previous] +
              (heights[previous] - heights[i]) / 2 +
              minSpacing,
          );
        }
        previous = i;
      }
      offsets.push(offset);
    }
    return offsets;
  };

  const labelled = new Set();
  const byProminence = group
    .map((node, i) => i)
    .sort((a, b) => group[b].value - group[a].value || a - b);
  for (const i of byProminence) {
    labelled.add(i);
    if (offsetsFor(labelled)[last] > room + TOLERANCE) {
      labelled.delete(i);
      break;
    }
  }
  const offsets = offsetsFor(labelled);
  if (offsets[last] > room + TOLERANCE) return;

  const lowest = lo;
  const highest = hi - heights[last] - offsets[last];

  // Subtracting the offsets turns the gap rules into "never above the
  // previous node"; pooling neighbours that break it finds the closest
  // such positions (isotonic regression), and clamping keeps them inside.
  const pools = [];
  group.forEach((node, i) => {
    pools.push({ sum: node.y0 - offsets[i], count: 1 });
    while (pools.length > 1) {
      const [before, after] = pools.slice(-2);
      if (before.sum / before.count <= after.sum / after.count) break;
      pools.splice(-2, 2, {
        sum: before.sum + after.sum,
        count: before.count + after.count,
      });
    }
  });

  let i = 0;
  pools.forEach(({ sum: total, count }) => {
    const y = Math.min(Math.max(total / count, lowest), highest);
    for (let end = i + count; i < end; i++) {
      group[i].y0 = y + offsets[i];
      group[i].y1 = group[i].y0 + heights[i];
    }
  });
}

// Chart height and node padding that leave every node of the most crowded
// column (nodes laid out at `height` with `padding`) a label-sized gap. Only
// the gaps widen; the bars keep their size. Never shorter than `height`.
export function sankeyHeightForLabels(nodes, { height, padding, minSpacing }) {
  const gaps = Math.max(largestSankeyColumn(nodes) - 1, 1);
  const labelPadding = Math.max(Math.ceil(minSpacing), padding);

  return {
    height: Math.ceil(height + gaps * (labelPadding - padding)),
    padding: labelPadding,
  };
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

  if (lo > hi + TOLERANCE) return null;
  return Math.min(Math.max(y, lo), Math.max(lo, hi));
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
// Layout positions are fractional; a slot exactly one label tall must not be
// lost to rounding.
const TOLERANCE = 0.01;

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
