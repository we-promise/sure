import assert from "node:assert/strict";
import { test } from "node:test";
import { compareSankeyData } from "../../../app/javascript/utils/sankey_comparison.mjs";

const graph = () => ({
  nodes: [
    { id: "income_a", value: 30, percentage: 100 },
    { id: "cash_flow_node", value: 30, percentage: 100 },
    { id: "expense_b", value: 20, percentage: 66.7 },
    { id: "surplus_node", value: 10, percentage: 33.3 },
  ],
  links: [
    { source: 0, target: 1, value: 30, percentage: 100 },
    { source: 1, target: 2, value: 20, percentage: 66.7 },
    { source: 1, target: 3, value: 10, percentage: 33.3 },
  ],
});

test("ignores ordering and display metadata without mutating either input", () => {
  const legacy = graph();
  const preview = {
    nodes: [...legacy.nodes].reverse().map((node) => ({ ...node, kind: "expense", color: "different", name: "Localized" })),
    links: [...legacy.links].reverse().map((link) => ({ ...link, source: 3 - link.source, target: 3 - link.target })),
  };
  const before = JSON.stringify([legacy, preview]);
  assert.equal(compareSankeyData(legacy, preview), "match");
  assert.equal(JSON.stringify([legacy, preview]), before);
});

test("detects changed amounts, percentages, identities, topology and duplicate links", () => {
  for (const mutate of [
    (data) => { data.nodes[0].value += 0.01; },
    (data) => { data.links[0].value += 0.01; },
    (data) => { data.links[0].percentage = 99; },
    (data) => { data.nodes[0].percentage = 99; },
    (data) => { data.nodes[0].id = "income_other"; },
    (data) => { data.links[0].target = 2; },
    (data) => { data.links.push({ ...data.links[0] }); },
    (data) => { data.links.pop(); },
  ]) {
    const changed = graph();
    mutate(changed);
    assert.equal(compareSankeyData(graph(), changed), "mismatch");
  }
});

test("compares empty charts and skips invalid or unavailable inputs", () => {
  const empty = { nodes: [], links: [] };
  assert.equal(compareSankeyData({ nodes: [{ id: "cash_flow_node", value: 0, percentage: 100 }], links: [] }, empty), "match");
  assert.equal(compareSankeyData(empty, graph()), "mismatch");
  assert.equal(compareSankeyData(null, graph()), null);
  const invalid = graph();
  invalid.links[0].source = 99;
  assert.equal(compareSankeyData(invalid, graph()), null);
  invalid.links[0].source = 0;
  invalid.nodes[0].value = NaN;
  assert.equal(compareSankeyData(invalid, graph()), null);
});


test("matches converted amounts at the original chart precision", () => {
  for (const [original, precise] of [
    [18330.03, 18330.0300864458], [18253.3, 18253.300864458],
    [1635.93, 1635.9291627454757], [10.44, 10.44362297733607],
    [1.01, 1.005], [10.08, 10.075], [0, 1e-8],
  ]) {
    const legacy = graph(), preview = graph();
    legacy.nodes[0].value = legacy.links[0].value = original;
    preview.nodes[0].value = preview.links[0].value = precise;
    assert.equal(compareSankeyData(legacy, preview), "match");
  }
});

test("normalizes synthetic category identities and their link endpoints across locales", () => {
  for (const [key, name] of [["uncategorized", "Uncategorized"], ["uncategorized", "Sin categoría"], ["other_investments", "Other Investments"]]) {
    const legacy = graph(), preview = graph();
    legacy.nodes[2] = { ...legacy.nodes[2], id: `expense_${name}`, name };
    preview.nodes[2] = { ...preview.nodes[2], id: `expense_${key}`, name, category_id: null };
    assert.equal(compareSankeyData(legacy, preview), "match");
    legacy.nodes[2].id = "expense_real-category-id";
    assert.equal(compareSankeyData(legacy, preview), "mismatch");
  }
});

test("preserves cent differences even when close to a rounding boundary", () => {
  const legacy = graph(), preview = graph();
  legacy.nodes[0].value = 10.44;
  preview.nodes[0].value = 10.445;
  assert.equal(compareSankeyData(legacy, preview), "mismatch");
});
