import assert from "node:assert/strict";
import { test } from "node:test";
import { layoutSankeyLabels } from "../../../app/javascript/utils/sankey_labels.mjs";

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

test("large graphs use tighter spacing", () => {
  const nodes = column([
    [500.0, 20, 22],
    [300.0, 31, 33],
  ]);
  assert.equal(hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING }).size, 1);
  assert.equal(hiddenSankeyLabels(nodes, { height: 800, minSpacing: SPACING }).size, 0);
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
