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
