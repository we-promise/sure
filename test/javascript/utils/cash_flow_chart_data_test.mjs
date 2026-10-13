import assert from "node:assert/strict";
import { test } from "node:test";
import {
  cashFlowChartData,
  formatCashFlowCurrency,
} from "../../../app/javascript/utils/cash_flow_chart_data.mjs";
const payload = () => ({
  currency: "JPY",
  sankey: {
    basis: "net_by_category",
    nodes: [
      {
        id: "income_one",
        name: "Income",
        kind: "income",
        value: "12.345",
        percentage: "100.0",
        color: "#123456",
      },
      {
        id: "cash_flow_node",
        name: "Cash Flow",
        kind: "cash_flow",
        value: "12.345",
        percentage: "100.0",
      },
    ],
    links: [{ source: 0, target: 1, value: "12.345", percentage: "100.0" }],
  },
});
test("maps graph geometry without rounding or changing API payload", () => {
  const body = payload();
  const graph = cashFlowChartData(body);
  assert.equal(graph.nodes[0].value, 12.345);
  assert.equal(body.sankey.nodes[0].value, "12.345");
  assert.equal(graph.nodes[0].color, "#123456");
});
test("accepts empty graphs", () => {
  assert.deepEqual(
    cashFlowChartData({
      currency: "USD",
      sankey: { basis: "net_by_category", nodes: [], links: [] },
    }),
    { nodes: [], links: [] },
  );
});
test("rejects malformed, unsafe, and cyclic graphs", () => {
  for (const mutate of [
    (p) => (p.sankey.nodes[0].value = "Infinity"),
    (p) => (p.sankey.nodes[0].value = "-1"),
    (p) => (p.sankey.links[0].value = "0"),
    (p) => (p.sankey.nodes[0].percentage = "101"),
    (p) => (p.sankey.nodes[0].id = "cash_flow_node"),
    (p) => (p.sankey.links[0].target = 9),
    (p) =>
      p.sankey.links.push({
        source: 1,
        target: 0,
        value: "1",
        percentage: "1",
      }),
  ]) {
    const body = payload();
    mutate(body);
    assert.throws(() => cashFlowChartData(body));
  }
});

test("formats zero-decimal currencies and Sure currencies outside Intl", () => {
  assert.equal(formatCashFlowCurrency(1234, "JPY", "en-US"), "¥1,234");
  assert.equal(formatCashFlowCurrency(1.234, "BHD", "en-US"), "BHD\u00a01.234");
  assert.equal(
    formatCashFlowCurrency(0.00000012, "DOGE", "en-US"),
    "0.00000012 DOGE",
  );
  const body = payload();
  body.currency = "DOGE";
  assert.equal(cashFlowChartData(body).links.length, 1);
});
