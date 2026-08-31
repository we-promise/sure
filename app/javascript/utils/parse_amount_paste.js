import parseLocaleFloat from "utils/parse_locale_float"

// A currency symbol or code, as it appears next to a pasted amount: "$", "R$",
// "kr", "USD". Capped at three characters so prose ("memo 500") is rejected
// rather than silently read as an amount.
const CURRENCY_TOKEN = "[^\\d\\s.,()+-]{1,3}"

const stripCurrency = (value) =>
  value
    .replace(new RegExp(`^${CURRENCY_TOKEN}\\s*`), "")
    .replace(new RegExp(`\\s*${CURRENCY_TOKEN}$`), "")
    .trim()

// Parses text pasted into a money field, or returns null when the text is not
// an amount at all.
//
// parseLocaleFloat coerces anything it cannot read to 0, which is unsafe for a
// paste: "$1,234.56", "USD 500" and "abc" would all silently overwrite the
// field with 0. So the text is matched against a strict grammar first — an
// optional sign, an optional currency symbol or code on either side, and a
// number — and anything else returns null so the browser handles the paste.
//
// The sign is read before the currency is stripped, because it can sit on
// either side of the symbol ("-$500", "$-500"), and because a negative that is
// only recognised after stripping would post a debit as a credit. Amounts
// wrapped in parentheses are negative, the convention used by most statement
// exports, and the currency may sit outside them ("USD (1,200.00)").
export default function parseAmountPaste(text, options = {}) {
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
