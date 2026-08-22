import assert from "node:assert/strict";
import test from "node:test";

import {
  sankeyNodeHasChildren,
  zoomSankeyData,
} from "../../../app/javascript/utils/sankey_zoom.mjs";

test("zooms an expense category to the clicked root and descendants", () => {
  const data = {
    nodes: [
      { id: "cash_flow_node", name: "Cash Flow" },
      { id: "expense_shopping", name: "Shopping" },
      { id: "expense_sub_groceries", name: "Groceries" },
      { id: "expense_sub_clothes", name: "Clothes" },
      { id: "expense_dining", name: "Dining" },
    ],
    links: [
      { source: 0, target: 1, value: 150 },
      { source: 1, target: 2, value: 100 },
      { source: 1, target: 3, value: 50 },
      { source: 0, target: 4, value: 75 },
    ],
    currency_symbol: "$",
  };

  assert.equal(sankeyNodeHasChildren(data, "expense_shopping"), true);
  assert.equal(sankeyNodeHasChildren(data, "expense_sub_groceries"), false);

  const zoomed = zoomSankeyData(data, "expense_shopping");

  assert.deepEqual(zoomed.nodes.map((node) => node.id), [
    "expense_shopping",
    "expense_sub_groceries",
    "expense_sub_clothes",
  ]);
  assert.deepEqual(
    zoomed.links.map((link) => [link.source, link.target, link.value]),
    [
      [0, 1, 100],
      [0, 2, 50],
    ],
  );
  assert.equal(zoomed.currency_symbol, "$");
});

test("zooms an income category by following incoming child links", () => {
  const data = {
    nodes: [
      { id: "income_salary", name: "Salary" },
      { id: "cash_flow_node", name: "Cash Flow" },
      { id: "income_sub_bonus", name: "Bonus" },
      { id: "income_sub_equity", name: "Equity" },
      { id: "income_interest", name: "Interest" },
    ],
    links: [
      { source: 0, target: 1, value: 250 },
      { source: 2, target: 0, value: 100 },
      { source: 3, target: 0, value: 150 },
      { source: 4, target: 1, value: 25 },
    ],
    currency_symbol: "$",
  };

  assert.equal(sankeyNodeHasChildren(data, "income_salary"), true);
  assert.equal(sankeyNodeHasChildren(data, "income_sub_bonus"), false);

  const zoomed = zoomSankeyData(data, "income_salary");

  assert.deepEqual(zoomed.nodes.map((node) => node.id), [
    "income_salary",
    "income_sub_bonus",
    "income_sub_equity",
  ]);
  assert.deepEqual(
    zoomed.links.map((link) => [link.source, link.target, link.value]),
    [
      [1, 0, 100],
      [2, 0, 150],
    ],
  );
});

test("zooms the cashflow node to its expense (outbound) descendants", () => {
  const data = {
    nodes: [
      { id: "income_salary", name: "Salary" },
      { id: "cash_flow_node", name: "Cash Flow" },
      { id: "expense_shopping", name: "Shopping" },
      { id: "expense_sub_groceries", name: "Groceries" },
    ],
    links: [
      { source: 0, target: 1, value: 200 },
      { source: 1, target: 2, value: 150 },
      { source: 2, target: 3, value: 100 },
    ],
  };

  assert.equal(sankeyNodeHasChildren(data, "cash_flow_node"), true);

  const zoomed = zoomSankeyData(data, "cash_flow_node");

  assert.deepEqual(zoomed.nodes.map((node) => node.id), [
    "cash_flow_node",
    "expense_shopping",
    "expense_sub_groceries",
  ]);
  assert.deepEqual(
    zoomed.links.map((link) => [link.source, link.target, link.value]),
    [
      [0, 1, 150],
      [1, 2, 100],
    ],
  );
});

test("does not zoom malformed data without a cashflow node", () => {
  const data = {
    nodes: [
      { id: "expense_shopping", name: "Shopping" },
      { id: "expense_sub_groceries", name: "Groceries" },
    ],
    links: [{ source: 0, target: 1, value: 100 }],
  };

  assert.equal(sankeyNodeHasChildren(data, "expense_shopping"), false);
  assert.equal(zoomSankeyData(data, "expense_shopping"), data);
});
