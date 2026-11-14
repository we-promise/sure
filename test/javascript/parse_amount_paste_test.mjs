import { readFile } from "node:fs/promises"
import { describe, it } from "node:test"
import assert from "node:assert/strict"

// The parser resolves "utils/parse_locale_float" through the importmap, which
// Node has no equivalent of, so the specifier is rewritten to a file URL and
// the module is imported as written. These cases therefore run the shipped
// parser rather than a copy of it that could drift.
const SOURCE_URL = new URL(
  "../../app/javascript/utils/parse_amount_paste.js",
  import.meta.url,
)
const PARSE_LOCALE_FLOAT_URL = new URL(
  "../../app/javascript/utils/parse_locale_float.js",
  import.meta.url,
)

const EVALUATE_AMOUNT_EXPRESSION_URL = new URL(
  "../../app/javascript/utils/evaluate_amount_expression.js",
  import.meta.url,
)

const source = (await readFile(SOURCE_URL, "utf8"))
  .replace('"utils/parse_locale_float"', JSON.stringify(PARSE_LOCALE_FLOAT_URL.href))
  .replace(
    '"utils/evaluate_amount_expression"',
    JSON.stringify(EVALUATE_AMOUNT_EXPRESSION_URL.href),
  )

const { default: evaluateAmountExpression } = await import(EVALUATE_AMOUNT_EXPRESSION_URL)

const { default: parseAmountPaste } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
)

describe("parseAmountPaste", () => {
  describe("parses plain and locale-formatted amounts", () => {
    it('parses "20,000 " as 20000', () => {
      assert.equal(parseAmountPaste("20,000 "), 20000)
    })

    it('parses "1.234,56" as 1234.56', () => {
      assert.equal(parseAmountPaste("1.234,56"), 1234.56)
    })

    it('parses "1 234.56" as 1234.56', () => {
      assert.equal(parseAmountPaste("1 234.56"), 1234.56)
    })

    it('parses "0.00001234" as 0.00001234', () => {
      assert.equal(parseAmountPaste("0.00001234"), 0.00001234)
    })
  })

  describe("strips currency symbols", () => {
    it('parses "$1,234.56" as 1234.56', () => {
      assert.equal(parseAmountPaste("$1,234.56"), 1234.56)
    })

    it('parses "1,234.56 €" as 1234.56', () => {
      assert.equal(parseAmountPaste("1,234.56 €"), 1234.56)
    })

    it('parses "£99.99" as 99.99', () => {
      assert.equal(parseAmountPaste("£99.99"), 99.99)
    })

    it('parses "₹500" as 500', () => {
      assert.equal(parseAmountPaste("₹500"), 500)
    })

    it('parses "¥1,200" as 1200', () => {
      assert.equal(parseAmountPaste("¥1,200"), 1200)
    })
  })

  describe("handles negatives", () => {
    it('parses "-45.20" as -45.2', () => {
      assert.equal(parseAmountPaste("-45.20"), -45.2)
    })

    it('parses "(1,200.00)" as -1200', () => {
      assert.equal(parseAmountPaste("(1,200.00)"), -1200)
    })

    it('parses "$-500" as -500', () => {
      assert.equal(parseAmountPaste("$-500"), -500)
    })

    it('parses "-$500" as -500', () => {
      assert.equal(parseAmountPaste("-$500"), -500)
    })

    it('parses "$(1,200.00)" as -1200', () => {
      assert.equal(parseAmountPaste("$(1,200.00)"), -1200)
    })

    it('parses "(1,200.00) €" as -1200', () => {
      assert.equal(parseAmountPaste("(1,200.00) €"), -1200)
    })
  })

  describe("rejects text that is not an amount (returns null)", () => {
    it('rejects "abc"', () => {
      assert.equal(parseAmountPaste("abc"), null)
    })

    it('rejects ""', () => {
      assert.equal(parseAmountPaste(""), null)
    })

    it('rejects "   "', () => {
      assert.equal(parseAmountPaste("   "), null)
    })

    it('rejects "12/31/2025"', () => {
      assert.equal(parseAmountPaste("12/31/2025"), null)
    })

    it('rejects "-"', () => {
      assert.equal(parseAmountPaste("-"), null)
    })

    it("rejects null", () => {
      assert.equal(parseAmountPaste(null), null)
    })

    it("rejects undefined", () => {
      assert.equal(parseAmountPaste(undefined), null)
    })

    it('rejects "memo 500"', () => {
      assert.equal(parseAmountPaste("memo 500"), null)
    })

    it('rejects "500 memo"', () => {
      assert.equal(parseAmountPaste("500 memo"), null)
    })

    it('rejects "fee 500"', () => {
      assert.equal(parseAmountPaste("fee 500"), null)
    })

    it('rejects "500 tax"', () => {
      assert.equal(parseAmountPaste("500 tax"), null)
    })

    it('rejects "TAX 500"', () => {
      assert.equal(parseAmountPaste("TAX 500"), null)
    })

    it('rejects "500 TAX"', () => {
      assert.equal(parseAmountPaste("500 TAX"), null)
    })

    it('rejects "*** 500"', () => {
      assert.equal(parseAmountPaste("*** 500"), null)
    })

    it('rejects "500 ***"', () => {
      assert.equal(parseAmountPaste("500 ***"), null)
    })

    it('rejects "R$ 1.234,56", since a lettered marker cannot be told from prose', () => {
      assert.equal(parseAmountPaste("R$ 1.234,56"), null)
    })

    it('rejects "USD 500", since a lettered code cannot be told from prose', () => {
      assert.equal(parseAmountPaste("USD 500"), null)
    })

    it('rejects "1,234.56 EUR", since a lettered code cannot be told from prose', () => {
      assert.equal(parseAmountPaste("1,234.56 EUR"), null)
    })
  })

  describe("settles a single separator before three digits with the currency's separator", () => {
    it('parses "1,234" as 1.234 for a comma-decimal currency', () => {
      assert.equal(parseAmountPaste("1,234", { separator: "," }), 1.234)
    })

    it('parses "1,234" as 1234 for a dot-decimal currency', () => {
      assert.equal(parseAmountPaste("1,234", { separator: "." }), 1234)
    })

    it('parses "1.234" as 1234 for a comma-decimal currency', () => {
      assert.equal(parseAmountPaste("1.234", { separator: "," }), 1234)
    })

    it('parses "1.234" as 1.234 for a dot-decimal currency', () => {
      assert.equal(parseAmountPaste("1.234", { separator: "." }), 1.234)
    })

    it('parses "€1,234" as 1.234 for a comma-decimal currency', () => {
      assert.equal(parseAmountPaste("€1,234", { separator: "," }), 1.234)
    })

    it('parses "-1,234" as -1.234 for a comma-decimal currency', () => {
      assert.equal(parseAmountPaste("-1,234", { separator: "," }), -1.234)
    })

    it('parses "1,234" as 1234 without a separator hint', () => {
      assert.equal(parseAmountPaste("1,234"), 1234)
    })
  })

  describe("ignores the currency's separator when the paste is unambiguous", () => {
    it('parses "$1,234.56" as 1234.56 for a comma-decimal currency', () => {
      assert.equal(parseAmountPaste("$1,234.56", { separator: "," }), 1234.56)
    })

    it('parses "1.234,56" as 1234.56 for a dot-decimal currency', () => {
      assert.equal(parseAmountPaste("1.234,56", { separator: "." }), 1234.56)
    })

    it('parses "1,234,567" as 1234567 for a comma-decimal currency', () => {
      assert.equal(parseAmountPaste("1,234,567", { separator: "," }), 1234567)
    })

    it('parses "1,5" as 1.5 for a dot-decimal currency', () => {
      assert.equal(parseAmountPaste("1,5", { separator: "." }), 1.5)
    })

    it('parses "1.5" as 1.5 for a comma-decimal currency', () => {
      assert.equal(parseAmountPaste("1.5", { separator: "," }), 1.5)
    })

    it('parses "1,2345" as 1.2345 for a dot-decimal currency', () => {
      assert.equal(parseAmountPaste("1,2345", { separator: "." }), 1.2345)
    })
  })

  describe("rejects multi-cell pastes rather than joining them", () => {
    it('rejects "100\\t200"', () => {
      assert.equal(parseAmountPaste("100\t200"), null)
    })

    it('rejects "1,234.56\\t500"', () => {
      assert.equal(parseAmountPaste("1,234.56\t500"), null)
    })

    it('rejects "100\\n200"', () => {
      assert.equal(parseAmountPaste("100\n200"), null)
    })

    it('still parses "1\\u00a0234,56" as 1234.56, since a no-break space groups digits', () => {
      assert.equal(parseAmountPaste("1\u00a0234,56"), 1234.56)
    })
  })

  describe("whole-number fields (precision 0, e.g. PYG, CLP, JPY)", () => {
    // Same rule as typing into the field: a dot or comma is grouping, so a
    // value means the same pasted as typed. The currency's separator hint
    // must not turn "1,500" into 1.5 (PYG's separator is ",").
    const pyg = { separator: ",", precision: 0 }
    const jpy = { separator: ".", precision: 0 }

    it('parses "150.000.000" as 150000000', () => {
      assert.equal(parseAmountPaste("150.000.000", pyg), 150000000)
    })

    it('parses "₲ 1.500.000" as 1500000', () => {
      assert.equal(parseAmountPaste("₲ 1.500.000", pyg), 1500000)
    })

    it('parses "-₲ 1.500" as -1500', () => {
      assert.equal(parseAmountPaste("-₲ 1.500", pyg), -1500)
    })

    it("reads a pasted amount the same as a typed one", () => {
      const whole = { precision: 0 }
      assert.equal(parseAmountPaste("1.000", jpy), evaluateAmountExpression("1.000", whole))
      assert.equal(parseAmountPaste("1,500", pyg), evaluateAmountExpression("1,500", whole))
    })

    it("leaves a non-grouped separator to the browser instead of rounding it", () => {
      assert.equal(parseAmountPaste("1.5", pyg), null)
      assert.equal(parseAmountPaste("$1,234.56", jpy), null)
    })

    it("accepts a zero cents part on a whole amount", () => {
      assert.equal(parseAmountPaste("₲ 150.000.000,00", pyg), 150000000)
      assert.equal(parseAmountPaste("¥1,000.00", jpy), 1000)
    })

    it("still parses plain and space-grouped integers", () => {
      assert.equal(parseAmountPaste("1500000", pyg), 1500000)
      assert.equal(parseAmountPaste("1 500 000", pyg), 1500000)
    })

    it("accepts a space-grouped amount with zero cents", () => {
      assert.equal(parseAmountPaste("1 234,00", jpy), 1234)
      assert.equal(parseAmountPaste("1\u00a0234,00", jpy), 1234)
      assert.equal(parseAmountPaste("1\u202f234\u202f567.00", pyg), 1234567)
    })

    it("accepts Indian grouping, as formatted for Indian locales", () => {
      assert.equal(parseAmountPaste("¥1,00,000", jpy), 100000)
      assert.equal(parseAmountPaste("¥12,34,567.00", jpy), 1234567)
    })

    it("still rejects mixed or uneven grouping", () => {
      assert.equal(parseAmountPaste("1 234.567", jpy), null)
      assert.equal(parseAmountPaste("1 234,5", jpy), null)
      assert.equal(parseAmountPaste("1.00.000", pyg), null)
      assert.equal(parseAmountPaste("1,00,00", jpy), null)
    })
  })
})
