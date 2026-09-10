// Only +, -, *, / are treated as operators; commas and dots always belong to
// a number (as a decimal or thousands separator), so tokenizing on these four
// characters is unambiguous.
const OPERATOR = /[+\-*/]/

// A valid number token: an optional sign, then a digit, then any run of
// digits/dot/comma/space (grouping space). Anything else (letters, an empty
// token, a bare sign) is not a number, so the whole input is rejected rather
// than silently parsed to 0. This is a coarse character-class check only —
// parseTypedNumber below still validates the *shape* (where the separators
// sit), so e.g. "12,50,30" passes this but is caught later.
const NUMBER = /^[+-]?\d[\d.,\u0020\u00a0\u202f]*$/

// Exhaustive shapes a cleaned (sign and grouping-space stripped) number can
// take. Anything that isn't one of these is rejected outright rather than
// guessed at — a money field is not the place to be lenient about what
// "1.2,3.4" or "1,,234" might have meant.
const INTEGER = /^\d+$/
const DOT_DECIMAL = /^\d+\.\d*$/
const COMMA_DECIMAL = /^\d+,\d*$/
const DOT_GROUPED = /^\d{1,3}(\.\d{3})+$/ // "1.234.567" — dot used only for grouping
const COMMA_GROUPED = /^\d{1,3}(,\d{3})+$/ // "1,234,567" — comma used only for grouping
const EURO_FORMAT = /^\d{1,3}(\.\d{3})+,\d+$/ // "1.234,56" — dot-grouped thousands + comma decimal
const US_FORMAT = /^\d{1,3}(,\d{3})+\.\d+$/ // "1,234.56" — comma-grouped thousands + dot decimal

// A sane upper bound on how long a single number token can be. Nothing
// resembling a real amount needs more than this; without a cap a
// pathological paste/typed string (thousands of digits) would still be
// handed to the regexes and Number.parseFloat for no legitimate reason.
const MAX_TOKEN_LENGTH = 32

// Splits a raw amount string into number/operator tokens, treating a +/- as
// a sign (part of the number) when it opens the string or follows another
// operator, and as a binary operator otherwise. Returns null if the string
// isn't a well-formed alternation of number, operator, number, ... .
function tokenize(trimmed) {
  const tokens = []
  let current = ""

  for (const ch of trimmed) {
    if (OPERATOR.test(ch)) {
      const isSign =
        current.trim() === "" &&
        (tokens.length === 0 || OPERATOR.test(tokens[tokens.length - 1]))
      if (isSign) {
        current += ch
        continue
      }
      tokens.push(current)
      tokens.push(ch)
      current = ""
    } else {
      current += ch
    }
  }
  tokens.push(current)

  if (tokens.length % 2 === 0) return null
  return tokens
}

// Parses one number token typed by hand into this field (as opposed to one
// pasted in from a bank statement, see parse_amount_paste.js/parseLocaleFloat
// — those favor a thousands-grouping reading of an ambiguous comma, because
// pasted statement data is often grouped). Someone typing digit by digit
// almost never adds a thousands separator, so a single comma or a single dot
// is read as *the* decimal point regardless of how many digits follow it —
// "10,321" is ten-point-three-two-one, not ten thousand three hundred
// twenty-one.
//
// A separator is only read as grouping when the token unambiguously has that
// shape: the same separator repeated in strict 3-digit groups ("1,234,567"),
// or a grouped integer followed by the other separator used once as the
// decimal point ("1.234,56", "1,234.56"). Anything that doesn't match one of
// these exact shapes — "12,50,30" (groups aren't 3 digits), "1,,234"
// (empty group), "1.2,3.4" (both separators, but not a recognized
// thousands+decimal shape) — is rejected rather than guessed at by quietly
// stripping whichever characters are "in the way".
function parseTypedNumber(token, { separator } = {}) {
  if (token.length > MAX_TOKEN_LENGTH) return null

  const negative = token.startsWith("-")
  const unsigned = token.replace(/^[+-]/, "")
  const cleaned = unsigned.replace(/[\u0020\u00a0\u202f]/g, "")

  let normalized = null

  if (separator === ",") {
    if (INTEGER.test(cleaned) || COMMA_DECIMAL.test(cleaned)) {
      normalized = cleaned.replace(",", ".")
    } else if (DOT_GROUPED.test(cleaned)) {
      normalized = cleaned.replace(/\./g, "")
    } else if (EURO_FORMAT.test(cleaned)) {
      normalized = cleaned.replace(/\./g, "").replace(",", ".")
    }
  } else if (separator === ".") {
    if (INTEGER.test(cleaned) || DOT_DECIMAL.test(cleaned)) {
      normalized = cleaned
    } else if (COMMA_GROUPED.test(cleaned)) {
      normalized = cleaned.replace(/,/g, "")
    } else if (US_FORMAT.test(cleaned)) {
      normalized = cleaned.replace(/,/g, "")
    }
  } else if (INTEGER.test(cleaned) || DOT_DECIMAL.test(cleaned)) {
    normalized = cleaned
  } else if (COMMA_DECIMAL.test(cleaned)) {
    normalized = cleaned.replace(",", ".")
  } else if (DOT_GROUPED.test(cleaned)) {
    normalized = cleaned.replace(/\./g, "")
  } else if (COMMA_GROUPED.test(cleaned)) {
    normalized = cleaned.replace(/,/g, "")
  } else if (EURO_FORMAT.test(cleaned)) {
    normalized = cleaned.replace(/\./g, "").replace(",", ".")
  } else if (US_FORMAT.test(cleaned)) {
    normalized = cleaned.replace(/,/g, "")
  }

  if (normalized === null) return null

  const value = Number.parseFloat(normalized)
  if (!Number.isFinite(value)) return null

  return negative ? -value : value
}

// Parses a money field's raw text as a single typed amount, or as a simple
// arithmetic expression over such amounts (e.g. "12,50 + 4,30" or "100/3"),
// evaluated left to right with the usual * / before + - precedence. Returns
// a finite number, or null when the text isn't a valid amount or expression
// (so the caller can leave the field untouched instead of overwriting a typo
// — or a deliberately malformed value — with 0).
export default function evaluateAmountExpression(value, options = {}) {
  if (typeof value !== "string") return null

  const trimmed = value.trim()
  if (trimmed === "" || trimmed.length > MAX_TOKEN_LENGTH * 8) return null

  const tokens = tokenize(trimmed)
  if (tokens === null) return null

  const numberTokens = tokens.filter((_, i) => i % 2 === 0)
  const operatorTokens = tokens.filter((_, i) => i % 2 === 1)

  if (numberTokens.some((t) => !NUMBER.test(t.trim()))) return null

  const numbers = numberTokens.map((t) => parseTypedNumber(t.trim(), options))
  if (numbers.some((n) => n === null)) return null

  if (operatorTokens.length === 0) {
    return numbers[0]
  }

  // First pass: resolve * and / (left to right), collapsing each result back
  // into place so the second pass only has to handle + and -.
  const values = [numbers[0]]
  const additive = []

  for (let i = 0; i < operatorTokens.length; i++) {
    const op = operatorTokens[i]
    const next = numbers[i + 1]

    if (op === "*" || op === "/") {
      if (op === "/" && next === 0) return null
      const prev = values.pop()
      values.push(op === "*" ? prev * next : prev / next)
    } else {
      additive.push(op)
      values.push(next)
    }
  }

  let result = values[0]
  for (let i = 0; i < additive.length; i++) {
    result = additive[i] === "+" ? result + values[i + 1] : result - values[i + 1]
  }

  return Number.isFinite(result) ? result : null
}

// Formats a parsed amount back into field text, matching whichever decimal
// separator the raw text the user typed actually used. `toFixed` always
// renders a dot (it isn't locale-aware), so without this a comma typed as
// "12,50" would flip back to "12.50" the instant the field is normalized —
// exported as a pure function (no DOM) so the round trip is covered by a
// plain unit test rather than only trusted to work inside a real browser.
export function formatAmountForDisplay(amount, precision, raw) {
  const formatted = precision === null ? String(amount) : amount.toFixed(precision)
  return typeof raw === "string" && raw.includes(",")
    ? formatted.replace(".", ",")
    : formatted
}
