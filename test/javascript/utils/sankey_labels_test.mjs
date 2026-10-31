import assert from "node:assert/strict";
import { test } from "node:test";
import { hiddenSankeyLabels } from "../../../app/javascript/utils/sankey_labels.mjs";

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

test("a small node above a large node no longer hides the large label", () => {
  // Demo-scale regression: Fees ($1.15) sat above Household ($160) and won
  // the label under the old top-down rule.
  const nodes = column([
    [1.15, 18, 20],
    [160.0, 10, 60],
    [928.21, 90, 240],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.equal(hidden.has(1), false, "large node keeps its label");
  assert.equal(hidden.has(0), true, "small neighbor yields");
  assert.equal(hidden.has(2), false);
});

test("spacing still hides the less prominent of two crowded large nodes", () => {
  const nodes = column([
    [500.0, 0, 20],
    [400.0, 22, 40],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.equal(hidden.has(0), false, "larger value keeps the label");
  assert.equal(hidden.has(1), true);
});

test("nodes spaced far enough apart all stay labeled", () => {
  const nodes = column([
    [5.99, 0, 4],
    [20.24, 40, 46],
    [1.15, 80, 82],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.equal(hidden.size, 0);
});

test("columns are independent of each other", () => {
  const nodes = [
    { index: 0, x0: 0, value: 10, y0: 0, y1: 10 },
    { index: 1, x0: 100, value: 10, y0: 0, y1: 10 },
    { index: 2, x0: 100, value: 20, y0: 12, y1: 22 },
  ];
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.equal(hidden.has(0), false);
  assert.equal(hidden.has(1), true, "smaller node in the shared column yields");
  assert.equal(hidden.has(2), false, "larger node in the shared column wins");
});

test("equal values fall back to vertical order deterministically", () => {
  const nodes = column([
    [50, 0, 10],
    [50, 12, 22],
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.equal(hidden.has(0), false, "top-most of equal values stays");
  assert.equal(hidden.has(1), true);
});

test("large graphs keep tall-bar labels and use tighter spacing", () => {
  const nodes = column([
    [300.0, 8, 38], // 18px from the higher-value node; needs the tall-bar override
    [500.0, 0, 10], // highest value claims its label first
    [200.0, 43, 53], // 25px from the tall bar; needs the reduced 19.6px spacing
  ]);
  const hidden = hiddenSankeyLabels(nodes, { height: 800, minSpacing: SPACING });
  assert.equal(hidden.has(0), false, "tall bar always labeled");
  assert.equal(hidden.has(1), false, "highest-value node keeps its label");
  assert.equal(hidden.has(2), false, "tighter spacing in large graphs");
});

test("hidden set uses node.index, not array position", () => {
  const nodes = [
    { index: 7, x0: 100, value: 1, y0: 28, y1: 30 },
    { index: 3, x0: 100, value: 100, y0: 6, y1: 60 },
  ];
  const hidden = hiddenSankeyLabels(nodes, { height: 400, minSpacing: SPACING });
  assert.deepEqual([...hidden], [7]);
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
