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
function parseAmountPaste(text, options = {}) {
  const trimmed = typeof text === "string" ? text.trim() : ""
  if (trimmed === "") return null

  const negative = trimmed.startsWith("-") || /^\(.*\)$/.test(trimmed)

  const body = trimmed
    .replace(/^[+-]/, "")
    .replace(/^[^\d]+/, "")
    .replace(/[^\d]+$/, "")

  if (!/^\d[\d.,\s]*$/.test(body)) return null

  const parsed = parseLocaleFloat(body, options)
  if (!Number.isFinite(parsed)) return null

  return negative ? -parsed : parsed
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
  })

  describe("handles negatives", () => {
    it('parses "-45.20" as -45.2', () => {
      assert.equal(parseAmountPaste("-45.20"), -45.2)
    })

    it('parses "(1,200.00)" as -1200', () => {
      assert.equal(parseAmountPaste("(1,200.00)"), -1200)
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
  })
})
