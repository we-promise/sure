import assert from "node:assert/strict";
import test from "node:test";

import {
  isNavigableCategoryNode,
  buildCategoryTransactionsUrl,
} from "../../../app/javascript/utils/transactions_filter_url.mjs";

test("category nodes are navigable, structural nodes are not", () => {
  assert.equal(isNavigableCategoryNode("expense_15"), true);
  assert.equal(isNavigableCategoryNode("income_3"), true);
  assert.equal(isNavigableCategoryNode("expense_sub_19"), true);
  assert.equal(isNavigableCategoryNode("income_sub_7"), true);
  assert.equal(isNavigableCategoryNode("cash_flow_node"), false);
  assert.equal(isNavigableCategoryNode("surplus_node"), false);
  // Bare aggregate ids are not category nodes.
  assert.equal(isNavigableCategoryNode("income"), false);
  assert.equal(isNavigableCategoryNode("expense"), false);
});

test("builds a transactions deep link with category and date range", () => {
  const url = buildCategoryTransactionsUrl({
    name: "Groceries",
    startDate: "2026-05-01",
    endDate: "2026-05-31",
  });
  assert.equal(
    url,
    "/transactions?q%5Bcategories%5D%5B%5D=Groceries&q%5Bstart_date%5D=2026-05-01&q%5Bend_date%5D=2026-05-31",
  );
});

test("encodes category names with special characters", () => {
  const url = buildCategoryTransactionsUrl({
    name: "Food & Drink",
    startDate: "2026-05-01",
    endDate: "2026-05-31",
  });
  assert.match(url, /q%5Bcategories%5D%5B%5D=Food\+%26\+Drink/);
});

test("omits date params when dates are blank", () => {
  const url = buildCategoryTransactionsUrl({
    name: "Groceries",
    startDate: "",
    endDate: "",
  });
  assert.equal(url, "/transactions?q%5Bcategories%5D%5B%5D=Groceries");
});
