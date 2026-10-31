import assert from "node:assert/strict";
import { test } from "node:test";
import {
  largestSankeyColumn,
  layoutSankeyLabels,
  sankeyHeightForLabels,
  sankeyLabelRoom,
  spreadSankeyColumns,
} from "../../../app/javascript/utils/sankey_labels.mjs";

const hiddenSankeyLabels = (nodes, options) => layoutSankeyLabels(nodes, options).hidden;

const SPACING = 28;

// One column (same depth) of vertically stacked nodes, top to bottom.
const column = (entries) =>
  entries.map(([value, y0, y1], i) => ({
    index: i,
    x0: 100,
    value,
    y0,
    y1,
  }));

test("a small node can't push a larger node's label off its bar centre", () => {
  // Demo-scale regression: Fees ($1.15) sat above Household ($160) and won
  // the label under the old top-down rule.
  const nodes = column([
    [1.15, 18, 20],
    [160.0, 22, 60],
    [928.21, 90, 240],
  ]);
  const { hidden, labelY } = layoutSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.deepEqual([...hidden], [0], "Fees yields");
  assert.equal(labelY.get(1), 41, "Household stays centred");
  assert.equal(labelY.get(2), 165);
});

test("a crowded smaller label slides into free space beside its bar", () => {
  const nodes = column([
    [160.0, 100, 140],
    [40.0, 142, 150],
  ]);
  const { hidden, labelY } = layoutSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.equal(hidden.size, 0);
  assert.equal(labelY.get(0), 120, "the larger label doesn't move");
  assert.equal(labelY.get(1), 148, "the smaller one moves just far enough");
});

test("when a column runs out of room the largest node keeps the label", () => {
  const nodes = column([
    [1.15, 19, 21],
    [160.0, 22, 24],
    [5.0, 25, 27],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.deepEqual([...hidden].sort(), [0, 2]);
});

test("a smaller node can't take the slot a larger crowded node gave up", () => {
  // 5.0 has no room beside 160; 0.5 just below could slide into the free
  // space, but labeling it while 5.0 stays hidden would invert the order.
  const nodes = column([
    [1.15, 19, 21],
    [160.0, 22, 24],
    [5.0, 25, 27],
    [0.5, 45, 46],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.equal(hidden.has(1), false);
  assert.equal(hidden.has(2), true);
  assert.equal(hidden.has(3), true, "0.5 doesn't jump into 5.0's place");
});

test("mid-sized nodes keep labels when the free space beside them can hold them", () => {
  // Expense column sorted large to small, small bars crowded at the bottom.
  const nodes = column([
    [500.0, 0, 100], // Food
    [60.0, 105, 115], // Transport
    [40.0, 120, 127], // Fun
    [5.0, 145, 146], // Fees
    [1.0, 150, 151], // Misc
  ]);
  const { hidden, labelY } = layoutSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.deepEqual([...hidden].sort(), [3, 4], "only the smallest run out of room");
  assert.equal(labelY.get(0), 50, "Food stays centred");
  assert.equal(labelY.get(1), 110, "Transport stays centred");
  assert.equal(labelY.get(2), 138, "Fun slides below Transport");
});

test("a label never slides off the chart", () => {
  const fits = column([
    [40, 355, 357],
    [30, 375, 377],
  ]);
  const { labelY } = layoutSankeyLabels(fits, { height: 400, minSpacing: SPACING });
  assert.equal(labelY.get(1), 384);

  const tooLow = column([
    [40, 359, 361],
    [30, 375, 377],
  ]);
  assert.deepEqual([...hiddenSankeyLabels(tooLow, { height: 400, minSpacing: SPACING })], [1]);
});

test("nodes spaced far enough apart all stay labeled where they are", () => {
  const nodes = column([
    [5.99, 0, 4],
    [20.24, 40, 46],
    [1.15, 80, 82],
  ]);
  const { hidden, labelY } = layoutSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.equal(hidden.size, 0);
  assert.deepEqual([...labelY.values()].sort((a, b) => a - b), [2, 43, 81]);
});

test("columns are independent of each other", () => {
  const nodes = [
    { index: 0, x0: 0, value: 10, y0: 0, y1: 10 },
    { index: 1, x0: 100, value: 10, y0: 0, y1: 2 },
    { index: 2, x0: 100, value: 20, y0: 3, y1: 5 },
  ];
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.equal(hidden.has(0), false);
  assert.equal(hidden.has(1), true, "smaller node in the shared column yields");
  assert.equal(hidden.has(2), false, "larger node in the shared column wins");
});

test("equal values fall back to vertical order deterministically", () => {
  const nodes = column([
    [50, 0, 2],
    [50, 3, 5],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.equal(hidden.has(0), false, "top-most of equal values stays");
  assert.equal(hidden.has(1), true);
});

test("tall charts keep the full label spacing", () => {
  // Labels are ~26px tall; packing them closer on tall charts made them overlap.
  const nodes = column([
    [500.0, 20, 22],
    [300.0, 31, 33],
  ]);
  assert.equal(hiddenSankeyLabels(nodes, { height: 800, minSpacing: SPACING }).size, 1);
});

test("hidden set uses node.index, not array position", () => {
  const nodes = [
    { index: 7, x0: 100, value: 1, y0: 10, y1: 12 },
    { index: 3, x0: 100, value: 100, y0: 13, y1: 15 },
  ];
  const hidden = hiddenSankeyLabels(nodes, { height: 40, minSpacing: SPACING });
  assert.deepEqual([...hidden], [7]);
});

test("a label that would cross another column's bar once moved stays hidden", () => {
  // Q fits beside its own bar, but only by sliding down onto the bar of the
  // next column; P, which never has to move that far, keeps its label.
  const nodes = [
    { index: 0, x0: 0, x1: 15, value: 100, y0: 40, y1: 42 },
    { index: 1, x0: 0, x1: 15, value: 50, y0: 43, y1: 45 },
    { index: 2, x0: 120, x1: 135, value: 1000, y0: 60, y1: 300 },
  ];
  const box = (y) => ({ x: 21, y: y - 13, width: 108, height: 26 });
  const labelBoxes = new Map([
    [0, box(41)],
    [1, box(44)],
    [2, { x: 141, y: 167, width: 70, height: 26 }],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING, labelBoxes });
  assert.equal(hidden.has(0), false);
  assert.equal(hidden.has(1), true);
  assert.equal(hidden.has(2), false);
});

test("same-depth nodes in different visual columns do not compete", () => {
  // d3-sankey justify alignment flushes sinks to the last column; a parent
  // one column left at the same y must not lose its label to the sink.
  const nodes = [
    { index: 0, x0: 100, value: 476.85, y0: 16, y1: 35.5 }, // parent, middle column
    { index: 1, x0: 300, value: 524.99, y0: 16, y1: 37.4 }, // sink, right column
  ];
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.equal(hidden.size, 0);
});

// On a phone the columns sit ~100px apart, so "Investment Income" beside the
// first column ran across the gap into the Cash Flow bar.
test("a label that would run into another column's bar yields", () => {
  const nodes = [
    { index: 0, x0: 0, x1: 15, value: 1042, y0: 250, y1: 254 },
    { index: 1, x0: 120, x1: 135, value: 61957, y0: 60, y1: 300 },
  ];
  const labelBoxes = new Map([
    [0, { x: 21, y: 240, width: 108, height: 26 }],
    [1, { x: 141, y: 168, width: 70, height: 26 }],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING, labelBoxes });
  assert.equal(hidden.has(0), true, "label crossing the next bar yields");
  assert.equal(hidden.has(1), false);
});

test("a label that stops short of the next column keeps showing", () => {
  const nodes = [
    { index: 0, x0: 0, x1: 15, value: 9855, y0: 230, y1: 246 },
    { index: 1, x0: 120, x1: 135, value: 61957, y0: 60, y1: 300 },
  ];
  const labelBoxes = new Map([
    [0, { x: 21, y: 226, width: 60, height: 26 }],
    [1, { x: 141, y: 168, width: 70, height: 26 }],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING, labelBoxes });
  assert.equal(hidden.size, 0);
});

test("of two labels from different columns that would collide, the smaller yields", () => {
  const nodes = [
    { index: 0, x0: 120, x1: 135, value: 3230, y0: 100, y1: 110 }, // label runs right
    { index: 1, x0: 300, x1: 315, value: 21967, y0: 100, y1: 140 }, // label runs left
  ];
  const labelBoxes = new Map([
    [0, { x: 141, y: 92, width: 90, height: 26 }],
    [1, { x: 200, y: 108, width: 94, height: 26 }],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING, labelBoxes });
  assert.equal(hidden.has(1), false, "more prominent label keeps its place");
  assert.equal(hidden.has(0), true);
});

test("label boxes in the same column are left to the spacing rule", () => {
  const nodes = column([
    [500, 0, 20],
    [400, 30, 50],
  ]).map((node) => ({ ...node, x1: 115 }));
  const labelBoxes = new Map([
    [0, { x: 121, y: -3, width: 80, height: 26 }],
    [1, { x: 121, y: 26, width: 80, height: 26 }],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING, labelBoxes });
  assert.equal(hidden.size, 0);
});

test("a label rejected for crossing a bar doesn't keep its smaller neighbour hidden", () => {
  const nodes = [
    { index: 0, x0: 300, x1: 315, value: 1000, y0: 100, y1: 140 },
    { index: 1, x0: 300, x1: 315, value: 200, y0: 145, y1: 150 },
    { index: 2, x0: 200, x1: 215, value: 1500, y0: 100, y1: 160 },
  ];
  const labelBoxes = new Map([
    [0, { x: 190, y: 106, width: 104, height: 26 }],
    [1, { x: 240, y: 134, width: 54, height: 26 }],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING, labelBoxes });
  assert.equal(hidden.has(0), true, "crosses the bar to its left");
  assert.equal(hidden.has(1), false, "takes the place it was crowded out of");
  assert.equal(hidden.has(2), false);
});

// `count` nodes in the crowded right column next to a two-node left column.
const crowdedChart = (count) => [
  { index: 0, x0: 0, y0: 16, y1: 200, value: 1 },
  { index: 1, x0: 0, y0: 210, y1: 368, value: 1 },
  ...Array.from({ length: count }, (_, i) => ({
    index: i + 2,
    x0: 300,
    y0: 16 + i * 9,
    y1: 21 + i * 9,
    value: 1,
  })),
];

test("the largest column is counted by visual position", () => {
  assert.equal(largestSankeyColumn(crowdedChart(35)), 35);
  assert.equal(largestSankeyColumn([]), 0);
});

test("showing every label widens only the gaps of the crowded column", () => {
  const fitted = sankeyHeightForLabels(crowdedChart(35), {
    height: 384,
    padding: 1.5,
    minSpacing: SPACING,
  });
  assert.deepEqual(fitted, { height: Math.ceil(384 + 34 * (SPACING - 1.5)), padding: SPACING });
});

test("a chart whose gaps already fit a label keeps its height", () => {
  const fitted = sankeyHeightForLabels(crowdedChart(3), { height: 384, padding: 30, minSpacing: SPACING });
  assert.deepEqual(fitted, { height: 384, padding: 30 });
});

test("every label of the crowded column fits once the gaps have widened", () => {
  const count = 35;
  const { height, padding } = sankeyHeightForLabels(crowdedChart(count), {
    height: 384,
    padding: 1,
    minSpacing: SPACING,
  });
  const bar = (height - 32 - (count - 1) * padding) / count;
  const nodes = Array.from({ length: count }, (_, i) => ({
    index: i,
    x0: 300,
    y0: 16 + i * (bar + padding),
    y1: 16 + i * (bar + padding) + bar,
    value: count - i,
  }));
  assert.equal(hiddenSankeyLabels(nodes, { height, minSpacing: SPACING }).size, 0);
});

const SPREAD = { top: 16, bottom: 384, padding: 4, minSpacing: SPACING };

test("a column with spare height spreads its nodes just enough for every label", () => {
  // Left column: one large source, then four small ones packed under it.
  const nodes = column([
    [19821, 16, 146],
    [75, 150, 151],
    [2208, 155, 170],
    [3953, 174, 200],
    [1828, 204, 216],
  ]);
  spreadSankeyColumns({ nodes, links: [] }, SPREAD);
  const heights = [130, 1, 15, 26, 12];
  nodes.forEach((node, i) => assert.equal(node.y1 - node.y0, heights[i], "bars keep their size"));
  assert.equal(nodes[0].y0, 16, "the top node stays put");
  const centres = nodes.map((n) => (n.y0 + n.y1) / 2);
  centres.slice(1).forEach((c, i) => assert.ok(c - centres[i] >= SPACING - 1e-9, "labels have room"));
  assert.ok(nodes[4].y1 <= 384);
  assert.equal(hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING }).size, 0);
});

test("nodes that already have room for their labels don't move", () => {
  const nodes = column([
    [10, 16, 40],
    [10, 80, 100],
  ]);
  spreadSankeyColumns({ nodes, links: [] }, SPREAD);
  assert.deepEqual(nodes.map((n) => [n.y0, n.y1]), [[16, 40], [80, 100]]);
});

test("near the bottom, spreading pushes nodes up instead of off the chart", () => {
  const nodes = column([
    [10, 350, 360],
    [10, 362, 372],
    [10, 374, 384],
  ]);
  spreadSankeyColumns({ nodes, links: [] }, SPREAD);
  assert.equal(nodes[2].y1, 384);
  assert.ok(nodes[0].y0 < 350);
  assert.equal(hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING }).size, 0);
});

test("a column short of room gives label room to its largest nodes", () => {
  // Twenty small bars, values shuffled; only some labels can fit.
  const values = [3, 17, 8, 12, 1, 20, 5, 14, 9, 2, 19, 6, 11, 4, 16, 7, 13, 10, 18, 15];
  const nodes = column(values.map((value, i) => [value, 16 + i * 12, 22 + i * 12]));
  spreadSankeyColumns({ nodes, links: [] }, SPREAD);

  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  const shown = nodes.filter((node) => !hidden.has(node.index)).map((node) => node.value);
  assert.ok(shown.length > 1);
  assert.deepEqual(
    [...shown].sort((a, b) => b - a),
    [...values].sort((a, b) => b - a).slice(0, shown.length),
    "the labels shown are the largest values",
  );
  nodes.slice(1).forEach((node, i) => {
    assert.ok(Math.abs(node.y1 - node.y0 - 6) < 1e-9, "bars keep their size");
    assert.ok(node.y0 - nodes[i].y1 >= 4 - 1e-9, "gaps never shrink below the padding");
  });
  assert.ok(nodes[0].y0 >= 16 && nodes[19].y1 <= 384 + 1e-9);
});

test("a column with no room even for padding keeps its layout", () => {
  const packed = Array.from({ length: 20 }, (_, i) => [1, 16 + i * 19, 32 + i * 19]);
  const nodes = column(packed);
  spreadSankeyColumns({ nodes, links: [] }, SPREAD);
  assert.deepEqual(nodes.map((n) => [n.y0, n.y1]), packed.map(([, y0, y1]) => [y0, y1]));
});

test("nodes don't spread onto a link that passes through their column", () => {
  // Cash Flow (x 0) sends a wide link straight to Surplus (x 300), across the
  // categories at x 150; the categories must stay above it.
  const cash = { index: 0, x0: 0, x1: 15, value: 100, y0: 16, y1: 384 };
  const surplus = { index: 1, x0: 300, x1: 315, value: 60, y0: 200, y1: 384 };
  const categories = [0, 1, 2, 3, 4].map((i) => ({
    index: 2 + i,
    x0: 150,
    x1: 165,
    value: 5 - i,
    y0: 120 + i * 3,
    y1: 121 + i * 3,
  }));
  const link = { source: cash, target: surplus, y0: 300, y1: 292, width: 184 };
  const relinked = [];
  spreadSankeyColumns(
    { nodes: [cash, surplus, ...categories], links: [link] },
    { ...SPREAD, relink: () => relinked.push(true) },
  );
  assert.equal(relinked.length, 2, "links follow each round of moves");
  const bandTop = Math.min(300, 292) - 92 - 4;
  categories.forEach((node) => assert.ok(node.y1 <= bandTop + 1e-9, `${node.index} stays above the link`));
  const centres = categories.map((n) => (n.y0 + n.y1) / 2);
  centres.slice(1).forEach((c, i) => assert.ok(c - centres[i] >= SPACING - 1e-9));
});

test("each column is spread on its own", () => {
  const nodes = [
    { index: 0, x0: 0, value: 1, y0: 16, y1: 20 },
    { index: 1, x0: 0, value: 1, y0: 22, y1: 26 },
    { index: 2, x0: 300, value: 1, y0: 16, y1: 20 },
  ];
  spreadSankeyColumns({ nodes, links: [] }, SPREAD);
  assert.ok(nodes[1].y0 - nodes[0].y0 >= SPACING);
  assert.deepEqual([nodes[2].y0, nodes[2].y1], [16, 20]);
});

test("a crowded group in the middle of a column opens up both ways", () => {
  const nodes = column([
    [10, 197, 199],
    [10, 199, 201],
    [10, 201, 203],
  ]);
  spreadSankeyColumns({ nodes, links: [] }, SPREAD);
  assert.deepEqual(nodes.map((n) => n.y0 + 1), [200 - SPACING, 200, 200 + SPACING]);
});

test("a slot exactly one label tall survives fractional positions", () => {
  // Positions from a spread chart: label centres exactly SPACING apart,
  // which floating-point maths lands a hair short of.
  const nodes = column([
    [750.47, 86.81806511383212, 92.09133704783918],
    [27.34, 117.35864710487674, 117.55075505679456],
    [358.19, 144.19626751650793, 146.71313464516334],
  ]);
  assert.equal(hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING }).size, 0);
});

// A first-column node whose label runs right, towards the next column's bar.
const income = { index: 0, x0: 0, x1: 15, value: 476, y0: 390, y1: 410 };
const incomeBar = { index: 1, x0: 355, x1: 370, value: 4174, y0: 200, y1: 520 };

test("a label's room ends a little before the next column's bar at its height", () => {
  const box = { x: 21, y: 387, width: 300, height: 26 };
  assert.equal(sankeyLabelRoom(income, box, [income, incomeBar]), 355 - 21 - 4);
});

test("a bar at another height leaves the label unbounded", () => {
  const box = { x: 21, y: 387, width: 300, height: 26 };
  const higher = { ...incomeBar, y0: 100, y1: 300 };
  assert.equal(sankeyLabelRoom(income, box, [income, higher]), null);
});

test("a label left of its bar is bounded by the bar to its left", () => {
  const category = { index: 0, x0: 980, x1: 995, value: 60, y0: 405, y1: 410 };
  const cashFlow = { index: 1, x0: 668, x1: 683, value: 4174, y0: 200, y1: 520 };
  const box = { x: 760, y: 395, width: 214, height: 26 };
  assert.equal(sankeyLabelRoom(category, box, [category, cashFlow]), 974 - 683 - 4);
});

test("a node out of room keeps smaller neighbours within a label unlabeled", () => {
  // Health has no room under Food and Rent; Transport, 20px below it, would
  // fit, but in the place of Health's label.
  const nodes = column([
    [750, 100, 130], // Food
    [600, 134, 136], // Rent
    [141, 137, 139], // Health
    [27, 157, 159], // Transport
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.deepEqual([...hidden].sort(), [2, 3]);
});

test("further down a column, the largest of the smaller nodes get labels again", () => {
  const nodes = column([
    [750, 100, 130], // Food
    [600, 134, 136], // Rent
    [141, 137, 139], // Health, out of room
    [58, 250, 251], // Family help, far below with room
    [27, 253, 254], // too close to Family help
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.deepEqual([...hidden].sort(), [2, 4]);
});
