import { describe, it } from "node:test"
import assert from "node:assert/strict"

// Runs the shipped module directly, matching the other test/javascript files
// in this directory.
const MODULE_URL = new URL(
  "../../app/javascript/utils/evaluate_amount_expression.js",
  import.meta.url,
)

const { default: evaluateAmountExpression, formatAmountForDisplay, precisionFromStep } =
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

  describe("a single separator is always the decimal point (iOS bug report)", () => {
    // Someone typing digit by digit never adds a thousands separator, so
    // there's no ambiguity to resolve here — a lone comma or dot is always
    // the decimal point, however many digits follow it.
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

    it("reads a 3-digit comma amount as a decimal even though it looks like a thousands group", () => {
      assert.equal(evaluateAmountExpression("1,234"), 1.234)
      assert.equal(evaluateAmountExpression("12,345"), 12.345)
    })
  })

  describe("thousands grouping is not supported while typing — only when pasting", () => {
    // Grouping is a paste-only concern (parse_amount_paste.js/
    // parseLocaleFloat, unchanged by this module): pasted statement data is
    // often grouped, but nobody types a grouping separator digit by digit.
    // Anything with more than one comma/dot, in any combination, is
    // rejected outright rather than guessed at.
    it("rejects a repeated comma", () => {
      assert.equal(evaluateAmountExpression("1,234,567"), null)
    })

    it("rejects a repeated dot", () => {
      assert.equal(evaluateAmountExpression("1.234.567"), null)
    })

    it("rejects dot-thousands + comma-decimal (European grouped format)", () => {
      assert.equal(evaluateAmountExpression("1.234,56"), null)
    })

    it("rejects comma-thousands + dot-decimal (English grouped format)", () => {
      assert.equal(evaluateAmountExpression("1,234.56"), null)
    })

    it("intentionally reads the same literal text differently than pasting would", () => {
      // parseAmountPaste("1,234") -> 1234 (thousands, tested in
      // parse_amount_paste_test.mjs) because pasted statement data is
      // usually grouped. Typed input has no such context to lean on, so a
      // lone comma is always the decimal point instead — same text, two
      // different (and each internally consistent) readings depending on
      // how it arrived in the field.
      assert.equal(evaluateAmountExpression("1,234"), 1.234)
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

    it("rejects mixed separators regardless of shape", () => {
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
    it("ignores surrounding and internal spaces around operators", () => {
      assert.equal(evaluateAmountExpression("  12.50  +  4.30  "), 16.8)
    })

    it("rejects a space used as thousands grouping (not supported while typing)", () => {
      assert.equal(evaluateAmountExpression("1 234,56"), null)
      assert.equal(evaluateAmountExpression("12 50"), null)
    })

    it("trims incidental whitespace, including newlines, around a token", () => {
      assert.equal(evaluateAmountExpression("12\n+3"), 15)
    })
  })

  describe("magnitude bound (matches the old type=number min/max)", () => {
    it("accepts an amount right at the bound", () => {
      assert.equal(evaluateAmountExpression("99999999999999"), 99999999999999)
    })

    it("rejects a single amount over the bound", () => {
      assert.equal(evaluateAmountExpression("999999999999999"), null)
    })

    it("rejects an expression whose result exceeds the bound, even if each operand doesn't", () => {
      assert.equal(evaluateAmountExpression("99999999999999*10"), null)
    })

    it("rejects a negative amount over the bound", () => {
      assert.equal(evaluateAmountExpression("-999999999999999"), null)
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
      assert.equal(evaluateAmountExpression("1e400"), null)
    })

    it("rejects NaN/Infinity spelled out as text", () => {
      assert.equal(evaluateAmountExpression("NaN"), null)
      assert.equal(evaluateAmountExpression("Infinity"), null)
    })

    it("rejects a null byte or other control character embedded in a number", () => {
      assert.equal(evaluateAmountExpression("1\x002"), null)
      assert.equal(evaluateAmountExpression("12\x1b[31m3"), null)
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

  describe("separator hint (deterministic — for a future user/family decimal-separator preference)", () => {
    it("accepts the hinted separator", () => {
      assert.equal(evaluateAmountExpression("1,234", { separator: "," }), 1.234)
      assert.equal(evaluateAmountExpression("1.234", { separator: "." }), 1.234)
    })

    it("rejects the other separator instead of reinterpreting it as grouping", () => {
      assert.equal(evaluateAmountExpression("1,234", { separator: "." }), null)
      assert.equal(evaluateAmountExpression("1.234", { separator: "," }), null)
    })

    it("applies the hint to every operand in an expression", () => {
      assert.equal(
        evaluateAmountExpression("1,234+1", { separator: "," }),
        2.234,
      )
      assert.equal(evaluateAmountExpression("1,234+1", { separator: "." }), null)
    })

    it("still rejects malformed groups under a hint", () => {
      assert.equal(evaluateAmountExpression("12,50,30", { separator: "," }), null)
      assert.equal(evaluateAmountExpression("1,,234", { separator: "," }), null)
    })

    it("plain integers are unaffected by the hint", () => {
      assert.equal(evaluateAmountExpression("1234", { separator: "," }), 1234)
      assert.equal(evaluateAmountExpression("1234", { separator: "." }), 1234)
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

  it("only substitutes the decimal point, not a negative sign", () => {
    assert.equal(formatAmountForDisplay(-12.5, 2, "-12,50"), "-12,50")
  })

  describe('null precision (step="any" fields, e.g. crypto price/fee)', () => {
    it("rounds away float drift instead of rendering it verbatim", () => {
      // 0.1 + 0.2 in IEEE-754 double math is 0.30000000000000004.
      assert.equal(formatAmountForDisplay(0.1 + 0.2, null, "0.1+0.2"), "0.3")
    })

    it("keeps a sub-cent crypto price intact", () => {
      assert.equal(formatAmountForDisplay(0.00000001, null, "0.00000001"), "0.00000001")
    })

    it("never falls back to exponential notation for a very small amount", () => {
      const formatted = formatAmountForDisplay(0.0000000001, null, "0.0000000001")
      assert.ok(!formatted.includes("e"), `expected no exponential notation, got ${formatted}`)
    })

    it("renders a whole number without a trailing decimal point", () => {
      assert.equal(formatAmountForDisplay(12, null, "12"), "12")
    })

    it("still substitutes a comma when the raw text used one", () => {
      assert.equal(formatAmountForDisplay(0.1 + 0.2, null, "0,1+0,2"), "0,3")
    })
  })
})

describe("precisionFromStep", () => {
  it("derives 2 decimal places from a 0.01 step", () => {
    assert.equal(precisionFromStep("0.01"), 2)
  })

  it("derives 0 decimal places from a whole-number step", () => {
    assert.equal(precisionFromStep("1"), 0)
  })

  it("derives 8 decimal places from BTC's exponential step", () => {
    assert.equal(precisionFromStep("1.0e-08"), 8)
  })

  it("returns null for step=\"any\"", () => {
    assert.equal(precisionFromStep("any"), null)
  })

  it("returns null for a zero or negative step", () => {
    assert.equal(precisionFromStep("0"), null)
    assert.equal(precisionFromStep("-1"), null)
  })

  it("returns null for an empty or missing step", () => {
    assert.equal(precisionFromStep(""), null)
    assert.equal(precisionFromStep(undefined), null)
  })
})
