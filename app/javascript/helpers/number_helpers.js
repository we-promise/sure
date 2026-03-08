/**
 * Parse a user-entered number that may use a comma as the decimal separator
 * (common in French, German, Spanish, Portuguese, and other locales).
 *
 * Examples:
 *   "256,54"    → 256.54   (French/German: comma is decimal)
 *   "1.256,54"  → 1256.54  (German: dot thousands, comma decimal)
 *   "1,256.54"  → 1256.54  (US: comma thousands, dot decimal)
 *   "256.54"    → 256.54   (standard)
 *   "256"       → 256
 *   ""          → 0
 *
 * Strategy: whichever separator appears last is the decimal separator.
 * All prior occurrences of the other separator are treated as thousands
 * grouping and stripped.
 *
 * @param {string|number} value
 * @returns {number}
 */
export function parseLocalized(value) {
  if (value === null || value === undefined || value === "") return 0

  const s = String(value).trim()
  if (!s) return 0

  const lastComma = s.lastIndexOf(",")
  const lastDot   = s.lastIndexOf(".")

  let normalized

  if (lastComma > lastDot) {
    // Comma is the decimal separator (e.g. "1.256,54" or "256,54")
    normalized = s.replace(/\./g, "").replace(",", ".")
  } else {
    // Dot is the decimal separator, or no fractional part (e.g. "1,256.54" or "256")
    normalized = s.replace(/,/g, "")
  }

  return Number.parseFloat(normalized) || 0
}
