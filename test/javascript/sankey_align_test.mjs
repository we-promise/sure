import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { sankeyLabelOnRight } from "../../app/javascript/utils/sankey_align.mjs"

describe("sankeyLabelOnRight", () => {
  const WIDTH = 1000
  const nodes = [
    { id: "income_work", layer: 1, x0: 200 },
    { id: "cash_flow_node", layer: 2, x0: 492 },
    { id: "expense_food", layer: 3, x0: 744 },
    { id: "surplus_node", layer: 3, x0: 744 },
    { id: "expense_sub_uk_tax", layer: 4, x0: 969 },
  ]
  const onRight = sankeyLabelOnRight(nodes, WIDTH)

  it("faces labels towards the middle of the chart", () => {
    assert.equal(onRight(nodes[0]), true)
    assert.equal(onRight(nodes[1]), true)
    assert.equal(onRight(nodes[2]), false)
    assert.equal(onRight(nodes[4]), false)
  })

  it("puts the surplus label on its right, away from the Cash Flow label", () => {
    assert.equal(onRight(nodes[3]), true)
  })

  it("keeps a surplus in the last column facing the middle", () => {
    const threeColumns = [
      { id: "cash_flow_node", layer: 1, x0: 492 },
      { id: "surplus_node", layer: 2, x0: 969 },
    ]
    assert.equal(sankeyLabelOnRight(threeColumns, WIDTH)(threeColumns[1]), false)
  })
})
