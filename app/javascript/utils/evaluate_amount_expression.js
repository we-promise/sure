// Only +, -, *, / are treated as operators; commas and dots always belong to
// a number (as a decimal separator), so tokenizing on these four characters
// is unambiguous.
const OPERATOR = /[+\-*/]/

// A valid number token: an optional sign, then a digit, then any run of
// digits/dot/comma. Anything else (letters, an empty token, a bare sign) is
// not a number, so the whole input is rejected rather than silently parsed
// to 0. This is a coarse character-class check only — parseTypedNumber below
// still validates that at most one separator is present.
const NUMBER = /^[+-]?\d[\d.,]*$/

// A sane upper bound on how long a single number token can be. Nothing
// resembling a real amount needs more than this; without a cap a
// pathological typed string (thousands of digits) would still be handed to
// the regexes and Number.parseFloat for no legitimate reason.
const MAX_TOKEN_LENGTH = 32

// Matches the old type="number" field's min/max attributes (dropped when the
// field became a text input, see the PR that introduced this file) — the
// amount columns are decimal(19,4), and nothing resembling a real
// transaction needs a 15-digit amount. Checked on every parsed operand and
// on the final result, so neither a single huge typed number nor an
// expression that multiplies its way past this bound reaches the server.
const MAX_AMOUNT = 99999999999999

// Parses one number token typed by hand into this field (as opposed to one
// pasted in from a bank statement — see parse_amount_paste.js/
// parseLocaleFloat, which favor a thousands-grouping reading of an
// ambiguous comma, because pasted statement data is often grouped).
//
// Someone typing digit by digit essentially never adds a thousands
// separator, and trying to guess when they *might* have — "is this comma a
// decimal point, or the start of a 3-digit group, or a typo?" — is exactly
// what kept producing new edge cases (bug reports: "10,321" silently became
// 10321; later, inputs with more than one separator like "12,50,30" or
// "1.2,3.4" were silently mis-parsed instead of rejected). Rather than add
// another shape to recognize, typed input now allows **at most one**
// separator (comma or dot) in a number, full stop — and that separator is
// always the decimal point, however many digits follow it. Two or more
// separators, in any combination, is not a supported way to type a number
// here and is rejected outright, with no attempt to guess what was meant.
// Thousands grouping remains fully supported when *pasting*, via the
// separate, unchanged parseAmountPaste/parseLocaleFloat path.
//
// An explicit `separator` hint (e.g. from a future user/family decimal-
// separator preference, mirroring the existing date format setting) locks
// in which single character is accepted as the decimal point — a token
// using the other one is then rejected rather than silently accepted, so
// once that preference exists there is no ambiguity left to resolve at all.
function parseTypedNumber(token, { separator } = {}) {
  if (token.length > MAX_TOKEN_LENGTH) return null

  const negative = token.startsWith("-")
  const unsigned = token.replace(/^[+-]/, "")

  const separators = unsigned.match(/[.,]/g) || []
  if (separators.length > 1) return null

  let normalized
  if (separators.length === 0) {
    if (!/^\d+$/.test(unsigned)) return null
    normalized = unsigned
  } else {
    const decimalChar = separators[0]
    if (separator && decimalChar !== separator) return null

    const shape = decimalChar === "." ? /^\d+\.\d*$/ : /^\d+,\d*$/
    if (!shape.test(unsigned)) return null

    normalized = unsigned.replace(decimalChar, ".")
  }

  const value = Number.parseFloat(normalized)
  if (!Number.isFinite(value) || Math.abs(value) > MAX_AMOUNT) return null

  return negative ? -value : value
}

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

// Parses a money field's raw text as a single typed amount, or as a simple
// arithmetic expression over such amounts (e.g. "12,50 + 4,30" or "100/3"),
// evaluated left to right with the usual * / before + - precedence. Returns
// a finite, sanely-bounded number, or null when the text isn't a valid
// amount or expression (so the caller can leave the field untouched instead
// of overwriting a typo — or a deliberately malformed value — with 0).
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

  if (!Number.isFinite(result) || Math.abs(result) > MAX_AMOUNT) return null

  return result
}

// toFixed rounds away IEEE-754 float drift (e.g. "0.1+0.2" evaluates to
// 0.30000000000000004) but, unlike Number/String round-tripping, never
// switches to exponential notation for very small magnitudes — that only
// happens when a number below 1e-6 is converted back through Number()/
// String(). Trimming the padding zeros toFixed leaves behind keeps a
// sub-cent crypto price ("0.00000001") intact instead of rounding it to 0.
export function formatUnroundedAmount(amount) {
  const fixed = amount.toFixed(10)
  return fixed.includes(".") ? fixed.replace(/0+$/, "").replace(/\.$/, "") : fixed
}

// Formats a parsed amount back into field text, matching whichever decimal
// separator the raw text the user typed actually used. `toFixed` always
// renders a dot (it isn't locale-aware), so without this a comma typed as
// "12,50" would flip back to "12.50" the instant the field is normalized —
// exported as a pure function (no DOM) so the round trip is covered by a
// plain unit test rather than only trusted to work inside a real browser.
export function formatAmountForDisplay(amount, precision, raw) {
  const formatted =
    precision === null ? formatUnroundedAmount(amount) : amount.toFixed(precision)
  return typeof raw === "string" && raw.includes(",")
    ? formatted.replace(".", ",")
    : formatted
}
