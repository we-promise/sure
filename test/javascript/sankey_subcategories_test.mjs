import { readFile } from "node:fs/promises"
import { describe, it } from "node:test"
import assert from "node:assert/strict"

// The helper resolves "utils/sankey_zoom" through the importmap, which Node
// has no equivalent of, so the specifier is rewritten to a file URL and the
// module is imported as written.
const SOURCE_URL = new URL("../../app/javascript/utils/sankey_subcategories.mjs", import.meta.url)
const SANKEY_ZOOM_URL = new URL("../../app/javascript/utils/sankey_zoom.mjs", import.meta.url)

const source = (await readFile(SOURCE_URL, "utf8")).replace(
  '"utils/sankey_zoom"',
  JSON.stringify(SANKEY_ZOOM_URL.href),
)

const { withoutSankeySubcategories } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
)

// Cash Flow -> Taxes -> UK Tax, Cash Flow -> Food, Salary -> Income -> Cash Flow,
// plus a subcategory that nets against its parent and so links to Cash Flow directly.
const data = {
  currency_symbol: "£",
  nodes: [
    { id: "cash_flow_node", name: "Cash Flow", value: 100 },
    { id: "income_1", name: "Income", value: 100 },
    { id: "income_sub_2", name: "Salary", value: 100 },
    { id: "expense_3", name: "Taxes", value: 60 },
    { id: "expense_sub_4", name: "UK Tax", value: 60 },
    { id: "expense_5", name: "Food", value: 30 },
    { id: "expense_sub_6", name: "Refunds", value: 10 },
  ],
  links: [
    { source: 1, target: 0, value: 100 },
    { source: 2, target: 1, value: 100 },
    { source: 0, target: 3, value: 60 },
    { source: 3, target: 4, value: 60 },
    { source: 0, target: 5, value: 30 },
    { source: 0, target: 6, value: 10 },
  ],
}

describe("withoutSankeySubcategories", () => {
  it("drops subcategories under a parent and reindexes the remaining links", () => {
    const result = withoutSankeySubcategories(data)

    assert.deepEqual(result.nodes.map((n) => n.name), ["Cash Flow", "Income", "Taxes", "Food", "Refunds"])
    assert.deepEqual(
      result.links.map((l) => [result.nodes[l.source].name, result.nodes[l.target].name, l.value]),
      [["Income", "Cash Flow", 100], ["Cash Flow", "Taxes", 60], ["Cash Flow", "Food", 30], ["Cash Flow", "Refunds", 10]],
    )
    assert.equal(result.currency_symbol, "£")
  })

  it("keeps a subcategory that flows straight to Cash Flow", () => {
    const result = withoutSankeySubcategories(data)

    assert.ok(result.nodes.some((n) => n.id === "expense_sub_6"))
  })

  it("accepts links whose endpoints are node objects, as d3 rewrites them", () => {
    const linked = {
      ...data,
      links: data.links.map((l) => ({ ...l, source: { index: l.source }, target: { index: l.target } })),
    }

    assert.equal(withoutSankeySubcategories(linked).nodes.length, 5)
  })

  it("returns the data untouched when there is nothing to collapse", () => {
    const flat = { nodes: data.nodes.slice(0, 2), links: data.links.slice(0, 1) }

    assert.equal(withoutSankeySubcategories(flat), flat)
    assert.equal(withoutSankeySubcategories({ nodes: [{ id: "x_sub_1" }], links: [] }).nodes.length, 1)
  })

  it("does not mutate its input", () => {
    const before = JSON.stringify(data)
    withoutSankeySubcategories(data)

    assert.equal(JSON.stringify(data), before)
  })
})
