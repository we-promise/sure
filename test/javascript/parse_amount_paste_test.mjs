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

const source = (await readFile(SOURCE_URL, "utf8")).replace(
  '"utils/parse_locale_float"',
  JSON.stringify(PARSE_LOCALE_FLOAT_URL.href),
)

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
})
