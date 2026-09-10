import { describe, it } from "node:test"
import assert from "node:assert/strict"

// Runs the shipped module directly, matching the other test/javascript files
// in this directory.
const MODULE_URL = new URL(
  "../../app/javascript/utils/evaluate_amount_expression.js",
  import.meta.url,
)

const { default: evaluateAmountExpression, formatAmountForDisplay } =
  await import(MODULE_URL)

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

    it("parses a trailing separator with no digits after it", () => {
      assert.equal(evaluateAmountExpression("12."), 12)
      assert.equal(evaluateAmountExpression("12,"), 12)
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

  describe("thousands grouping (only accepted in strict 3-digit groups)", () => {
    it("treats a repeated comma as thousands grouping", () => {
      assert.equal(evaluateAmountExpression("1,234,567"), 1234567)
    })

    it("treats a repeated dot as thousands grouping", () => {
      assert.equal(evaluateAmountExpression("1.234.567"), 1234567)
    })

    it("a single separator is always the decimal point, never grouping — even with 3 digits after it", () => {
      // This is the inverse of "treats a repeated comma/dot as thousands
      // grouping" above: grouping only kicks in once the separator repeats
      // (2+ groups). A single occurrence is always read as the decimal
      // point, matching the iOS bug report's "10,321" case.
      assert.equal(evaluateAmountExpression("12,345"), 12.345)
      assert.equal(evaluateAmountExpression("1,234"), 1.234)
    })

    it("resolves dot-thousands + comma-decimal (European) via last separator", () => {
      assert.equal(evaluateAmountExpression("1.234,56"), 1234.56)
    })

    it("resolves comma-thousands + dot-decimal (English) via last separator", () => {
      assert.equal(evaluateAmountExpression("1,234.56"), 1234.56)
    })

    it("resolves multi-group European amounts", () => {
      assert.equal(evaluateAmountExpression("12.345.678,90"), 12345678.9)
    })
  })

  describe("malformed separator use is rejected, not guessed at", () => {
    it("rejects groups that aren't exactly 3 digits", () => {
      assert.equal(evaluateAmountExpression("12,50,30"), null)
      assert.equal(evaluateAmountExpression("1,23,456"), null)
      assert.equal(evaluateAmountExpression("12.50.30"), null)
    })

    it("rejects a double separator with an empty group", () => {
      assert.equal(evaluateAmountExpression("1,,234"), null)
      assert.equal(evaluateAmountExpression("1..234"), null)
      assert.equal(evaluateAmountExpression(",,"), null)
      assert.equal(evaluateAmountExpression(".."), null)
    })

    it("rejects mixed separators that don't form a recognized thousands+decimal shape", () => {
      assert.equal(evaluateAmountExpression("1.2,3.4"), null)
      assert.equal(evaluateAmountExpression("1,2.3,4"), null)
      assert.equal(evaluateAmountExpression("1,234.56,78"), null)
      assert.equal(evaluateAmountExpression("1.234,56.78"), null)
    })

    it("rejects two decimal points of the same kind", () => {
      assert.equal(evaluateAmountExpression("12.50.00"), null)
      assert.equal(evaluateAmountExpression("12,50,00"), null)
    })

    it("rejects a separator with nothing before it", () => {
      assert.equal(evaluateAmountExpression(","), null)
      assert.equal(evaluateAmountExpression("."), null)
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

    it("rejects a malformed operand inside an expression", () => {
      assert.equal(evaluateAmountExpression("12,50,30+1"), null)
      assert.equal(evaluateAmountExpression("1+12,50,30"), null)
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
      assert.equal(evaluateAmountExpression("/12"), null)
    })

    it("rejects a lone sign", () => {
      assert.equal(evaluateAmountExpression("-"), null)
      assert.equal(evaluateAmountExpression("+"), null)
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
      assert.equal(evaluateAmountExpression({}), null)
      assert.equal(evaluateAmountExpression([1, 2]), null)
      assert.equal(evaluateAmountExpression(true), null)
    })
  })

  describe("deliberately adversarial input (malformed, oversized, or injection-shaped)", () => {
    it("rejects HTML/script-looking payloads", () => {
      assert.equal(evaluateAmountExpression("<script>alert(1)</script>"), null)
      assert.equal(evaluateAmountExpression("<img src=x onerror=alert(1)>"), null)
      assert.equal(evaluateAmountExpression("javascript:alert(1)"), null)
    })

    it("rejects SQL-injection-shaped strings", () => {
      assert.equal(evaluateAmountExpression("1; DROP TABLE users;--"), null)
      assert.equal(evaluateAmountExpression("1' OR '1'='1"), null)
    })

    it("rejects JS-prototype-shaped strings", () => {
      assert.equal(evaluateAmountExpression("__proto__"), null)
      assert.equal(evaluateAmountExpression("constructor.constructor"), null)
    })

    it("rejects template-literal/expression-injection-shaped strings", () => {
      assert.equal(evaluateAmountExpression("${alert(1)}"), null)
      assert.equal(evaluateAmountExpression("`${1+1}`"), null)
    })

    it("rejects a very long digit string instead of hanging or overflowing silently", () => {
      const huge = "9".repeat(400)
      assert.equal(evaluateAmountExpression(huge), null)
    })

    it("rejects a very long expression instead of hanging", () => {
      const longExpr = Array(500).fill("1").join("+")
      assert.equal(evaluateAmountExpression(longExpr), null)
    })

    it("rejects a number so large it would parse to Infinity", () => {
      // Below the MAX_TOKEN_LENGTH cut-off in digit count, but still
      // astronomically large — must be rejected via the finite check, not
      // silently accepted as Infinity.
      assert.equal(evaluateAmountExpression("1e400"), null)
    })

    it("rejects NaN/Infinity spelled out as text", () => {
      assert.equal(evaluateAmountExpression("NaN"), null)
      assert.equal(evaluateAmountExpression("Infinity"), null)
    })

    it("tolerates a plain grouping space between digits (by design, same as pasted grouped amounts)", () => {
      assert.equal(evaluateAmountExpression("12 50"), 1250)
    })

    it("rejects a null byte or other control character embedded in a number", () => {
      assert.equal(evaluateAmountExpression("1\x002"), null)
      assert.equal(evaluateAmountExpression("12\x1b[31m3"), null)
    })

    it("trims incidental surrounding whitespace, including newlines, same as spaces", () => {
      assert.equal(evaluateAmountExpression("12\n+3"), 15)
    })

    it("rejects full-width/unicode digit look-alikes", () => {
      // U+FF11 etc. ("１２" fullwidth) are not ASCII digits and must not be
      // silently treated as 0/rejected-to-0 — they should be refused outright.
      assert.equal(evaluateAmountExpression("１２"), null)
    })

    it("rejects whitespace-only input", () => {
      assert.equal(evaluateAmountExpression("   "), null)
      assert.equal(evaluateAmountExpression("\t\n"), null)
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

    it("still rejects malformed groups under a hint", () => {
      assert.equal(evaluateAmountExpression("12,50,30", { separator: "." }), null)
      assert.equal(evaluateAmountExpression("1,,234", { separator: "," }), null)
    })
  })
})

describe("formatAmountForDisplay", () => {
  it("renders a dot when the raw text had no comma", () => {
    assert.equal(formatAmountForDisplay(12.5, 2, "12.50"), "12.50")
  })

  it("renders a comma when the raw text the user typed had one", () => {
    assert.equal(formatAmountForDisplay(12.5, 2, "12,50"), "12,50")
  })

  it("re-renders a 3-decimal comma amount rounded to the field's precision", () => {
    // The exact iOS bug report round trip: "10,321" evaluates to 10.321,
    // and at 2-decimal precision must redisplay as "10,32", not "10.32".
    assert.equal(formatAmountForDisplay(10.321, 2, "10,321"), "10,32")
  })

  it("uses a comma even when the comma was inside an expression, not the result", () => {
    assert.equal(formatAmountForDisplay(16.8, 2, "12,50+4,30"), "16,80")
  })

  it("renders without rounding when precision is null", () => {
    assert.equal(formatAmountForDisplay(1.23456789, null, "1,23456789"), "1,23456789")
  })

  it("only substitutes the decimal point, not a negative sign", () => {
    assert.equal(formatAmountForDisplay(-12.5, 2, "-12,50"), "-12,50")
  })
})
