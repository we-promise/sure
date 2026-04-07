// Parses a float from a string that may use either commas or dots as decimal separators.
// Handles formats like "1,234.56" (English) and "1.234,56" (French/European).
//
// When a `separator` hint is provided (e.g., from currency metadata), parsing is
// deterministic. Without a hint, a heuristic detects the format from the string.
export default function parseLocaleFloat(value, { separator } = {}) {
  if (typeof value !== "string") return Number.parseFloat(value) || 0

  const cleaned = value.replace(/\s/g, "")

  // Deterministic parsing when the currency's decimal separator is known
  if (separator === ",") {
    return Number.parseFloat(cleaned.replace(/\./g, "").replace(",", ".")) || 0
  }
  if (separator === ".") {
    return Number.parseFloat(cleaned.replace(/,/g, "")) || 0
  }

  // Heuristic: detect separator from the string when no hint is available
  const lastComma = cleaned.lastIndexOf(",")
  const lastDot = cleaned.lastIndexOf(".")

  if (lastComma > lastDot) {
    // When there's no dot present and exactly 3 digits follow the last comma,
    // treat comma as a thousands separator (e.g., "1,234" → 1234, "12,345" → 12345)
    const digitsAfterComma = cleaned.length - lastComma - 1
    if (lastDot === -1 && digitsAfterComma === 3) {
      return Number.parseFloat(cleaned.replace(/,/g, "")) || 0
    }

    // Comma is the decimal separator (e.g., "1.234,56" or "256,54")
    return Number.parseFloat(cleaned.replace(/\./g, "").replace(",", ".")) || 0
  }

  // Dot is the decimal separator (e.g., "1,234.56" or "256.54")
  return Number.parseFloat(cleaned.replace(/,/g, "")) || 0
}
