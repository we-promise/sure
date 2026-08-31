import parseLocaleFloat from "utils/parse_locale_float"

// Parses text pasted into a money field, or returns null when the text is not
// an amount at all.
//
// parseLocaleFloat coerces anything it cannot read to 0, which is unsafe for a
// paste: "$1,234.56", "USD 500" and "abc" would all silently overwrite the
// field with 0. So the text is validated here first. A leading or trailing
// currency symbol or code is stripped, since both are common when copying from
// a statement, and whatever is left must be digits with , . or spaces as
// separators. Anything else returns null, and the browser handles the paste.
//
// Amounts wrapped in parentheses are read as negative, the accounting
// convention used by most statement exports.
export default function parseAmountPaste(text, options = {}) {
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
