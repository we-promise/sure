/**
 * Locale-aware number parsing for user-entered decimal values.
 *
 * HTML inputs of type="text" with inputmode="decimal" preserve the raw string
 * the user typed, so Number.parseFloat("256,54") returns 256 (stops at comma).
 * This helper normalises various decimal separator conventions before parsing.
 *
 * Supported formats:
 *   "256.54"    → 256.54   (standard)
 *   "256,54"    → 256.54   (French / EU comma-decimal)
 *   "1,234.56"  → 1234.56  (English thousands separator)
 *   "1.234,56"  → 1234.56  (German / EU thousands + comma-decimal)
 *   "1 234,56"  → 1234.56  (French space thousands + comma-decimal)
 *
 * @param {string|number} value - The raw input value to parse.
 * @returns {number} The parsed float, or NaN if unparseable.
 */
export function parseLocalizedFloat(value) {
  if (value === null || value === undefined || value === "") return NaN;
  if (typeof value === "number") return value;

  const str = String(value).trim();

  const lastComma = str.lastIndexOf(",");
  const lastPeriod = str.lastIndexOf(".");

  let normalized;

  if (lastComma === -1 && lastPeriod === -1) {
    // No separator — integer or unparseable
    normalized = str.replace(/\s/g, "");
  } else if (lastComma === -1) {
    // Only periods — standard format (may have thousands: "1.234.567" is ambiguous;
    // treat as-is since it's the common case)
    normalized = str.replace(/\s/g, "");
  } else if (lastPeriod === -1) {
    // Only commas — comma is the decimal separator ("256,54" or "1.234,56" impossible here)
    // Check for multiple commas (thousands): "1,234,567" → treat commas as thousands
    const commaCount = (str.match(/,/g) || []).length;
    if (commaCount > 1) {
      // Multiple commas: English-style thousands ("1,234,567")
      normalized = str.replace(/,/g, "").replace(/\s/g, "");
    } else {
      // Single comma: decimal separator ("256,54" → "256.54")
      normalized = str.replace(/\s/g, "").replace(",", ".");
    }
  } else if (lastComma > lastPeriod) {
    // Comma comes after last period → comma is the decimal separator
    // e.g. "1.234,56" (EU format) or "1 234,56"
    normalized = str.replace(/[\s.]/g, "").replace(",", ".");
  } else {
    // Period comes after last comma → period is the decimal separator
    // e.g. "1,234.56" (English format)
    normalized = str.replace(/[\s,]/g, "");
  }

  return Number.parseFloat(normalized);
}
