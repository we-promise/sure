import parseLocaleFloat from "utils/parse_locale_float"

// The currency symbols carried by config/currencies.yml, restricted to the
// ones that contain no letters. A letter-bearing marker ("kr", "R$", "USD")
// cannot be told apart from prose such as "fee 500" or "TAX 500" without
// consulting the currency list itself, and a paste event has nothing to await,
// so those pastes fall through to the browser untouched.
const CURRENCY_SYMBOL = "[$£¥֏؋৳฿៛₡₦₨₩₪₫€₭₮₱₲₴₵₸₹₺₼₽₾₿﷼]"

// Only the spaces that locales actually use to group digits ("1 234,56") are
// allowed inside the number. Any other whitespace is a token boundary, not a
// separator, so a multi-cell spreadsheet paste ("100\t200") is rejected rather
// than concatenated into one amount.
const GROUPED_NUMBER = /^([+-]?)(\d[\d.,\u0020\u00a0\u202f]*)$/

const stripCurrency = (value) =>
  value
    .replace(new RegExp(`^${CURRENCY_SYMBOL}\\s*`), "")
    .replace(new RegExp(`\\s*${CURRENCY_SYMBOL}$`), "")
    .trim()

// Parses text pasted into a money field, or returns null when the text is not
// an amount at all.
//
// parseLocaleFloat coerces anything it cannot read to 0, which is unsafe for a
// paste: "$1,234.56", "USD 500" and "abc" would all silently overwrite the
// field with 0. So the text is matched against a strict grammar first — an
// optional sign, an optional currency symbol on either side, and a number —
// and anything else returns null so the browser handles the paste.
//
// The sign is read before the currency is stripped, because it can sit on
// either side of the symbol ("-$500", "$-500"), and because a negative that is
// only recognised after stripping would post a debit as a credit. Amounts
// wrapped in parentheses are negative, the convention used by most statement
// exports, and the symbol may sit outside them ("$(1,200.00)").
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

  const match = rest.match(GROUPED_NUMBER)
  if (!match) return null
  if (match[1] === "-") negative = true

  const parsed = parseLocaleFloat(match[2], options)
  if (!Number.isFinite(parsed)) return null

  return negative ? -Math.abs(parsed) : parsed
}
