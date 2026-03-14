// Parses a float from a string that may use either commas or dots as decimal separators.
// Handles formats like "1,234.56" (English) and "1.234,56" (French/European).
export default function parseLocaleFloat(value) {
  if (typeof value !== "string") return Number.parseFloat(value) || 0

  const cleaned = value.replace(/\s/g, "")
  const lastComma = cleaned.lastIndexOf(",")
  const lastDot = cleaned.lastIndexOf(".")

  if (lastComma > lastDot) {
    // Comma is the decimal separator (e.g., "1.234,56" or "256,54")
    return Number.parseFloat(cleaned.replace(/\./g, "").replace(",", ".")) || 0
  }

  // Dot is the decimal separator (e.g., "1,234.56" or "256.54")
  return Number.parseFloat(cleaned.replace(/,/g, "")) || 0
}
