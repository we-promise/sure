import { readFile } from "node:fs/promises"
import { describe, it } from "node:test"
import assert from "node:assert/strict"

// Runs the shipped module directly (no bundler needed for a plain .js file
// with no importmap-only specifiers), matching the other test/javascript
// files in this directory.
const SOURCE_URL = new URL(
  "../../app/javascript/utils/evaluate_amount_expression.js",
  import.meta.url,
)

const { default: evaluateAmountExpression } = await import(SOURCE_URL)

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

    it("parses zero", () => {
      assert.equal(evaluateAmountExpression("0"), 0)
    })

    it("parses a leading-zero decimal", () => {
      assert.equal(evaluateAmountExpression("0.5"), 0.5)
      assert.equal(evaluateAmountExpression("0,5"), 0.5)
    })
  })

  describe("comma decimal with more than two decimal places (iOS bug report)", () => {
    it("reads a 3-decimal comma amount as a decimal, not thousands", () => {
      assert.equal(evaluateAmountExpression("10,321"), 10.321)
    })

    it("reads a 1-decimal comma amount correctly", () => {
      assert.equal(evaluateAmountExpression("10,3"), 10.3)
    })

    it("reads a 4-decimal comma amount correctly", () => {
      assert.equal(evaluateAmountExpression("10,3210"), 10.321)
    })

    it("still reads the classic 2-decimal comma case correctly", () => {
      assert.equal(evaluateAmountExpression("256,54"), 256.54)
    })
  })

  describe("thousands grouping (unambiguous only — repeated separator, or both present)", () => {
    it("treats a repeated comma as thousands grouping", () => {
      assert.equal(evaluateAmountExpression("1,234,567"), 1234567)
    })

    it("treats a repeated dot as thousands grouping", () => {
      assert.equal(evaluateAmountExpression("1.234.567"), 1234567)
    })

    it("resolves dot-thousands + comma-decimal (European) via last separator", () => {
      assert.equal(evaluateAmountExpression("1.234,56"), 1234.56)
    })

    it("resolves comma-thousands + dot-decimal (English) via last separator", () => {
      assert.equal(evaluateAmountExpression("1,234.56"), 1234.56)
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

    it("subtracts to a negative result", () => {
      assert.equal(evaluateAmountExpression("3-10"), -7)
    })

    it("adds three or more terms", () => {
      assert.equal(evaluateAmountExpression("1+2+3+4+5"), 15)
    })
  })

  describe("multiplication and division", () => {
    it("multiplies", () => {
      assert.equal(evaluateAmountExpression("12*3"), 36)
    })

    it("divides", () => {
      assert.equal(evaluateAmountExpression("100/4"), 25)
    })

    it("divides to a repeating decimal", () => {
      assert.equal(evaluateAmountExpression("10/3"), 10 / 3)
    })

    it("applies * and / before + and -", () => {
      assert.equal(evaluateAmountExpression("10+2*3"), 16)
      assert.equal(evaluateAmountExpression("2*3+10"), 16)
      assert.equal(evaluateAmountExpression("20-10/2"), 15)
    })

    it("chains multiplications and divisions left to right", () => {
      assert.equal(evaluateAmountExpression("100/4/5"), 5)
      assert.equal(evaluateAmountExpression("2*3*4"), 24)
    })

    it("multiplies a comma-decimal amount", () => {
      assert.equal(evaluateAmountExpression("12,50*2"), 25)
    })

    it("divides a comma-decimal amount", () => {
      assert.equal(evaluateAmountExpression("25,00/2"), 12.5)
    })

    it("multiplies by a negative number", () => {
      assert.equal(evaluateAmountExpression("12*-3"), -36)
    })
  })

  describe("mixed precedence chains", () => {
    it("evaluates a long mixed chain left to right with precedence", () => {
      // 2 + 3*4 - 6/3 = 2 + 12 - 2 = 12
      assert.equal(evaluateAmountExpression("2+3*4-6/3"), 12)
    })

    it("evaluates another mixed chain", () => {
      // 100 - 4*5 + 10/2 = 100 - 20 + 5 = 85
      assert.equal(evaluateAmountExpression("100-4*5+10/2"), 85)
    })

    it("evaluates a chain starting with multiplication", () => {
      // 3*4/2+1 = 12/2+1 = 6+1 = 7
      assert.equal(evaluateAmountExpression("3*4/2+1"), 7)
    })
  })

  describe("whitespace tolerance", () => {
    it("ignores surrounding and internal spaces", () => {
      assert.equal(evaluateAmountExpression("  12.50  +  4.30  "), 16.8)
    })

    it("ignores spaces used as thousands grouping", () => {
      assert.equal(evaluateAmountExpression("1 234,56"), 1234.56)
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

    it("rejects a leading operator with no sign meaning", () => {
      assert.equal(evaluateAmountExpression("*12"), null)
    })

    it("rejects a lone sign", () => {
      assert.equal(evaluateAmountExpression("-"), null)
    })

    it("rejects division by zero", () => {
      assert.equal(evaluateAmountExpression("5/0"), null)
    })

    it("rejects division by zero mid-chain", () => {
      assert.equal(evaluateAmountExpression("5+10/0"), null)
    })

    it("rejects a number with letters mixed in", () => {
      assert.equal(evaluateAmountExpression("12a+3"), null)
    })

    it("rejects non-string input", () => {
      assert.equal(evaluateAmountExpression(42), null)
      assert.equal(evaluateAmountExpression(null), null)
      assert.equal(evaluateAmountExpression(undefined), null)
    })
  })

  describe("separator hint (deterministic, overrides the typed-input heuristic)", () => {
    it("forces comma as the decimal separator", () => {
      assert.equal(evaluateAmountExpression("1,234", { separator: "," }), 1.234)
    })

    it("forces dot as the decimal separator, comma as grouping", () => {
      assert.equal(evaluateAmountExpression("1,234", { separator: "." }), 1234)
    })

    it("applies the hint to every operand in an expression", () => {
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
