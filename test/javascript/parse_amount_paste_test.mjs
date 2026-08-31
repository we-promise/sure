import { describe, it } from "node:test"
import assert from "node:assert/strict"

// Inline the function to avoid needing a bundler for ESM imports.
// Must be kept in sync with app/javascript/utils/parse_locale_float.js
function parseLocaleFloat(value, { separator } = {}) {
  if (typeof value !== "string") return Number.parseFloat(value) || 0

  const cleaned = value.replace(/\s/g, "")

  if (separator === ",") {
    return Number.parseFloat(cleaned.replace(/\./g, "").replace(",", ".")) || 0
  }
  if (separator === ".") {
    return Number.parseFloat(cleaned.replace(/,/g, "")) || 0
  }

  const lastComma = cleaned.lastIndexOf(",")
  const lastDot = cleaned.lastIndexOf(".")

  if (lastComma > lastDot) {
    const digitsAfterComma = cleaned.length - lastComma - 1
    if (lastDot === -1 && digitsAfterComma === 3) {
      return Number.parseFloat(cleaned.replace(/,/g, "")) || 0
    }

    return Number.parseFloat(cleaned.replace(/\./g, "").replace(",", ".")) || 0
  }

  return Number.parseFloat(cleaned.replace(/,/g, "")) || 0
}

// Inline the function to avoid needing a bundler for ESM imports.
// Must be kept in sync with app/javascript/utils/parse_amount_paste.js
// A currency marker sitting next to a pasted amount: either a symbol ("$",
// "€", "£"), which by definition carries no letters, or a three-letter
// uppercase ISO code ("USD", "EUR").
//
// Letters are otherwise excluded because a lowercase letter run is
// indistinguishable from prose without a real currency list — and the server's
// currency set is not available synchronously inside a paste event. That means
// markers containing letters, such as "R$" or "kr", are not stripped and those
// pastes fall through to the browser, which is the safe direction: accepting
// them would also accept "fee 500".
const CURRENCY_TOKEN = "(?:[^\\p{L}\\p{N}\\s.,()+-]{1,3}|[A-Z]{3})"

const stripCurrency = (value) =>
  value
    .replace(new RegExp(`^${CURRENCY_TOKEN}\\s*`, "u"), "")
    .replace(new RegExp(`\\s*${CURRENCY_TOKEN}$`, "u"), "")
    .trim()

function parseAmountPaste(text, options = {}) {
  const trimmed = typeof text === "string" ? text.trim() : ""
  if (trimmed === "") return null

  let rest = trimmed
  let negative = false

  const outerSign = rest.match(/^([+-])\s*/)
  if (outerSign) {
    negative = outerSign[1] === "-"
    rest = rest.slice(outerSign[0].length)
  }

  rest = stripCurrency(rest)

  const parenthesised = rest.match(/^\((.+)\)$/)
  if (parenthesised) {
    negative = true
    rest = stripCurrency(parenthesised[1].trim())
  }

  const match = rest.match(/^([+-]?)(\d[\d.,\s]*)$/)
  if (!match) return null
  if (match[1] === "-") negative = true

  const parsed = parseLocaleFloat(match[2], options)
  if (!Number.isFinite(parsed)) return null

  return negative ? -Math.abs(parsed) : parsed
}

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

  describe("strips currency symbols and codes", () => {
    it('parses "$1,234.56" as 1234.56', () => {
      assert.equal(parseAmountPaste("$1,234.56"), 1234.56)
    })

    it('parses "USD 500" as 500', () => {
      assert.equal(parseAmountPaste("USD 500"), 500)
    })

    it('parses "1,234.56 EUR" as 1234.56', () => {
      assert.equal(parseAmountPaste("1,234.56 EUR"), 1234.56)
    })

    it('parses "1,234.56 €" as 1234.56', () => {
      assert.equal(parseAmountPaste("1,234.56 €"), 1234.56)
    })

    it('parses "£99.99" as 99.99', () => {
      assert.equal(parseAmountPaste("£99.99"), 99.99)
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

    it('parses "USD (1,200.00)" as -1200', () => {
      assert.equal(parseAmountPaste("USD (1,200.00)"), -1200)
    })

    it('parses "(1,200.00) USD" as -1200', () => {
      assert.equal(parseAmountPaste("(1,200.00) USD"), -1200)
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

    it('rejects "R$ 1.234,56", since a lettered marker cannot be told from prose', () => {
      assert.equal(parseAmountPaste("R$ 1.234,56"), null)
    })
  })
})
