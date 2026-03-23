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

describe("parseLocaleFloat", () => {
  describe("dot as decimal separator", () => {
    it("parses simple decimal", () => {
      assert.equal(parseLocaleFloat("256.54"), 256.54)
    })

    it("parses with thousands comma", () => {
      assert.equal(parseLocaleFloat("1,234.56"), 1234.56)
    })

    it("parses multiple thousands separators", () => {
      assert.equal(parseLocaleFloat("1,234,567.89"), 1234567.89)
    })

    it("parses integer with dot-zero", () => {
      assert.equal(parseLocaleFloat("100.00"), 100)
    })
  })

  describe("comma as decimal separator (European/French)", () => {
    it("parses simple decimal", () => {
      assert.equal(parseLocaleFloat("256,54"), 256.54)
    })

    it("parses with thousands dot", () => {
      assert.equal(parseLocaleFloat("1.234,56"), 1234.56)
    })

    it("parses multiple thousands separators", () => {
      assert.equal(parseLocaleFloat("1.234.567,89"), 1234567.89)
    })

    it("parses two-digit decimal", () => {
      assert.equal(parseLocaleFloat("10,50"), 10.5)
    })

    it("parses single-digit decimal", () => {
      assert.equal(parseLocaleFloat("10,5"), 10.5)
    })
  })

  describe("ambiguous comma with 3 trailing digits treated as thousands separator", () => {
    it("treats 1,234 as one thousand two hundred thirty-four", () => {
      assert.equal(parseLocaleFloat("1,234"), 1234)
    })

    it("treats 12,345 as twelve thousand three hundred forty-five", () => {
      assert.equal(parseLocaleFloat("12,345"), 12345)
    })

    it("treats 1,000 as one thousand", () => {
      assert.equal(parseLocaleFloat("1,000"), 1000)
    })

    it("treats 1,000,000 as one million", () => {
      assert.equal(parseLocaleFloat("1,000,000"), 1000000)
    })
  })

  describe("integers", () => {
    it("parses plain integer", () => {
      assert.equal(parseLocaleFloat("100"), 100)
    })

    it("parses zero", () => {
      assert.equal(parseLocaleFloat("0"), 0)
    })
  })

  describe("whitespace handling", () => {
    it("strips leading/trailing spaces", () => {
      assert.equal(parseLocaleFloat("  256.54  "), 256.54)
    })

    it("strips thousands space separator", () => {
      assert.equal(parseLocaleFloat("1 234,56"), 1234.56)
    })
  })

  describe("negative numbers", () => {
    it("parses negative dot-decimal", () => {
      assert.equal(parseLocaleFloat("-1,234.56"), -1234.56)
    })

    it("parses negative comma-decimal", () => {
      assert.equal(parseLocaleFloat("-1.234,56"), -1234.56)
    })

    it("parses simple negative", () => {
      assert.equal(parseLocaleFloat("-256.54"), -256.54)
    })

    it("parses negative European simple", () => {
      assert.equal(parseLocaleFloat("-256,54"), -256.54)
    })
  })

  describe("with separator hint", () => {
    describe("comma separator (European currencies like EUR)", () => {
      const opts = { separator: "," }

      it("disambiguates 1,234 as 1.234 (European decimal)", () => {
        assert.equal(parseLocaleFloat("1,234", opts), 1.234)
      })

      it("parses 1.234,56 correctly", () => {
        assert.equal(parseLocaleFloat("1.234,56", opts), 1234.56)
      })

      it("parses simple comma decimal", () => {
        assert.equal(parseLocaleFloat("256,54", opts), 256.54)
      })

      it("parses integer without separators", () => {
        assert.equal(parseLocaleFloat("1234", opts), 1234)
      })

      it("parses negative value", () => {
        assert.equal(parseLocaleFloat("-1.234,56", opts), -1234.56)
      })
    })

    describe("dot separator (English currencies like USD)", () => {
      const opts = { separator: "." }

      it("disambiguates 1,234 as 1234 (English thousands)", () => {
        assert.equal(parseLocaleFloat("1,234", opts), 1234)
      })

      it("parses 1,234.56 correctly", () => {
        assert.equal(parseLocaleFloat("1,234.56", opts), 1234.56)
      })

      it("parses simple dot decimal", () => {
        assert.equal(parseLocaleFloat("256.54", opts), 256.54)
      })

      it("parses integer without separators", () => {
        assert.equal(parseLocaleFloat("1234", opts), 1234)
      })

      it("parses negative value", () => {
        assert.equal(parseLocaleFloat("-1,234.56", opts), -1234.56)
      })
    })

    it("falls back to heuristic when no hint given", () => {
      assert.equal(parseLocaleFloat("1,234"), 1234)
      assert.equal(parseLocaleFloat("256,54"), 256.54)
    })
  })

  describe("edge cases", () => {
    it("returns 0 for empty string", () => {
      assert.equal(parseLocaleFloat(""), 0)
    })

    it("returns 0 for non-numeric string", () => {
      assert.equal(parseLocaleFloat("abc"), 0)
    })

    it("returns 0 for undefined", () => {
      assert.equal(parseLocaleFloat(undefined), 0)
    })

    it("returns 0 for null", () => {
      assert.equal(parseLocaleFloat(null), 0)
    })

    it("passes through numeric values", () => {
      assert.equal(parseLocaleFloat(42.5), 42.5)
    })

    it("returns 0 for NaN", () => {
      assert.equal(parseLocaleFloat(NaN), 0)
    })
  })
})
