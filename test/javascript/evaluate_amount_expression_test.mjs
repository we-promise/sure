import { readFile } from "node:fs/promises"
import { describe, it } from "node:test"
import assert from "node:assert/strict"

// See parse_amount_paste_test.mjs: the importmap specifier has no Node
// equivalent, so it's rewritten to a file URL and the shipped module is
// imported as written, rather than duplicating the implementation here.
const SOURCE_URL = new URL(
  "../../app/javascript/utils/evaluate_amount_expression.js",
  import.meta.url,
)
const PARSE_LOCALE_FLOAT_URL = new URL(
  "../../app/javascript/utils/parse_locale_float.js",
  import.meta.url,
)

const source = (await readFile(SOURCE_URL, "utf8")).replace(
  '"utils/parse_locale_float"',
  JSON.stringify(PARSE_LOCALE_FLOAT_URL.href),
)

const { default: evaluateAmountExpression } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
)

describe("evaluateAmountExpression", () => {
  describe("plain amounts (no operator)", () => {
    it("parses a dot-decimal amount", () => {
      assert.equal(evaluateAmountExpression("12.50"), 12.5)
    })

    it("parses a comma-decimal amount", () => {
      assert.equal(evaluateAmountExpression("12,50"), 12.5)
    })

    it("parses a plain integer", () => {
      assert.equal(evaluateAmountExpression("100"), 100)
    })

    it("parses a negative amount", () => {
      assert.equal(evaluateAmountExpression("-12.50"), -12.5)
    })
  })

  describe("addition and subtraction", () => {
    it("adds two amounts", () => {
      assert.equal(evaluateAmountExpression("12.50+4.30"), 16.8)
    })

    it("adds two comma-decimal amounts", () => {
      assert.equal(evaluateAmountExpression("12,50 + 4,30"), 16.8)
    })

    it("subtracts", () => {
      assert.equal(evaluateAmountExpression("20-4.5"), 15.5)
    })

    it("chains additions and subtractions", () => {
      assert.equal(evaluateAmountExpression("10+5-3+2"), 14)
    })

    it("adds a negative second operand", () => {
      assert.equal(evaluateAmountExpression("5+-3"), 2)
    })

    it("subtracts a negative second operand", () => {
      assert.equal(evaluateAmountExpression("5--3"), 8)
    })

    it("leads with a negative amount", () => {
      assert.equal(evaluateAmountExpression("-5+3"), -2)
    })
  })

  describe("multiplication and division", () => {
    it("multiplies", () => {
      assert.equal(evaluateAmountExpression("12*3"), 36)
    })

    it("divides", () => {
      assert.equal(evaluateAmountExpression("100/4"), 25)
    })

    it("applies * and / before + and -", () => {
      assert.equal(evaluateAmountExpression("10+2*3"), 16)
      assert.equal(evaluateAmountExpression("2*3+10"), 16)
      assert.equal(evaluateAmountExpression("20-10/2"), 15)
    })

    it("chains multiplications and divisions left to right", () => {
      assert.equal(evaluateAmountExpression("100/4/5"), 5)
    })
  })

  describe("whitespace tolerance", () => {
    it("ignores surrounding and internal spaces", () => {
      assert.equal(evaluateAmountExpression("  12.50  +  4.30  "), 16.8)
    })
  })

  describe("invalid input returns null instead of guessing", () => {
    it("rejects empty string", () => {
      assert.equal(evaluateAmountExpression(""), null)
    })

    it("rejects a non-numeric string", () => {
      assert.equal(evaluateAmountExpression("abc"), null)
    })

    it("rejects a trailing operator", () => {
      assert.equal(evaluateAmountExpression("12+"), null)
    })

    it("rejects a lone sign", () => {
      assert.equal(evaluateAmountExpression("-"), null)
    })

    it("rejects division by zero", () => {
      assert.equal(evaluateAmountExpression("5/0"), null)
    })

    it("rejects non-string input", () => {
      assert.equal(evaluateAmountExpression(42), null)
      assert.equal(evaluateAmountExpression(null), null)
      assert.equal(evaluateAmountExpression(undefined), null)
    })
  })

  describe("separator hint", () => {
    it("disambiguates thousands vs decimal per operand", () => {
      assert.equal(
        evaluateAmountExpression("1,234+1", { separator: "." }),
        1235,
      )
      assert.equal(
        evaluateAmountExpression("1,234+1", { separator: "," }),
        2.234,
      )
    })
  })
})
