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
//
// A whole-number field (`precision: 0`, e.g. PYG, CLP, JPY) has no decimal
// point to type, so there a dot or comma can only be thousands grouping:
// "150.000.000" is 150000000. Only exact three-digit groups with one
// grouping character are accepted; anything else ("150.5", "150.000000") is
// rejected rather than rounded to a fraction of what was meant. Pasting uses
// the same rule (parse_amount_paste.js), so a value means the same typed or
// pasted. It applies to the terms that are added or subtracted only: a factor
// of * or / keeps the decimal reading, so "1000*1.1" (10% tax) still works,
// as long as it is a plain decimal multiplier (WHOLE_NUMBER_DECIMAL_FACTOR)
// whose decimal point is not the currency's thousands delimiter (in PYG,
// CLP, VND or ISK it is typed "1000*1,1").
//
// A pasted amount may also be grouped with spaces ("1 234,00", as pl or nb
// write it) or in the Indian style ("1,00,000", which lib/money/formatting.rb
// emits for Indian locales). A typed token cannot contain a space, so the
// space form only ever comes from a paste.
//
// The leading group starts with 1-9: nobody groups 500 as "0.500", so that
// shape is a decimal and is rejected rather than read as 500.
const WHOLE_NUMBER_GROUPED = /^[1-9]\d{0,2}(?:([.,\u0020\u00a0\u202f])\d{3})(?:\1\d{3})*$/
const WHOLE_NUMBER_INDIAN_GROUPED = /^[1-9]\d?(?:,\d{2})+,\d{3}$/

// In a whole-number field a factor of * or / with a separator must be a plain
// decimal multiplier: 0 and some decimals ("0.125"), or a whole part with no
// leading zero and one or two decimals ("1.1", "1.25"). The decimals cannot
// all be zero. Anything else is rejected instead of guessed, because the same
// text as an amount reads as grouping or is rejected as a likely typo:
// "150.000*12" could mean 1800000 or 1800, and "150.00*12" is probably a
// mistyped "150.000*12".
//
// When the field knows its currency's thousands delimiter (`delimiter`, from
// config/currencies.yml), a factor's decimal point cannot be that character
// either: PYG writes 150.000 for a hundred and fifty thousand, so "150.50*12"
// in a PYG field is rejected, while "150,50*12" is 150.5 × 12. JPY's
// delimiter is a comma, so "165.5*40" stays a decimal there.
const WHOLE_NUMBER_DECIMAL_FACTOR = /^(?:0[.,](?!0+$)\d+|[1-9]\d*[.,](?!0{1,2}$)\d{1,2})$/

// Reads an unsigned digit string with a dot or comma in it as a grouped
// whole number, or returns null when it is not exactly that shape.
export function parseGroupedWholeNumber(input) {
  let digits = input
  // A zero cents part ("1.500.000,00", "1500.00") is still a whole amount, as
  // long as its separator is not the grouping one.
  const zeroCents = digits.match(/^(.+)([.,])0{1,2}$/)
  if (zeroCents && !zeroCents[1].includes(zeroCents[2])) {
    digits = zeroCents[1]
    // An ungrouped lead of up to three digits ("150.00") is more likely a
    // mistyped group ("150.000") than zero cents, so it is rejected.
    if (/^\d{1,3}$/.test(digits)) return null
    if (/^\d+$/.test(digits)) {
      const plain = Number.parseInt(digits, 10)
      return plain <= MAX_AMOUNT ? plain : null
    }
  }
  if (!WHOLE_NUMBER_GROUPED.test(digits) && !WHOLE_NUMBER_INDIAN_GROUPED.test(digits)) return null
  const value = Number.parseInt(digits.replace(/[^\d]/g, ""), 10)
  return Number.isFinite(value) && value <= MAX_AMOUNT ? value : null
}

// True when a number in the text reads as thousands grouping in a
// whole-number field ("150.000" in "150.000*12"). Such text means something
// else in a currency with decimals, so a currency switch must not silently
// take the new reading. Text that is merely invalid ("25.50") has no other
// reading and is not flagged, nor is a zero cents part alone ("1500,00"),
// which means 1500 either way.
export function hasWholeNumberGrouping(value) {
  if (typeof value !== "string") return false

  return value.split(OPERATOR).some((token) => {
    const unsigned = token.trim().replace(/^[+-]/, "")
    const lead = unsigned.replace(/[.,]0{1,2}$/, "")
    return /[.,]/.test(lead) && parseGroupedWholeNumber(unsigned) !== null
  })
}

function parseTypedNumber(token, { separator, precision } = {}) {
  if (token.length > MAX_TOKEN_LENGTH) return null

  const negative = token.startsWith("-")
  const unsigned = token.replace(/^[+-]/, "")

  if (precision === 0 && /[.,]/.test(unsigned)) {
    const value = parseGroupedWholeNumber(unsigned)
    if (value === null) return null
    return negative ? -value : value
  }

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

  // A factor of * or / is a multiplier, not an amount, so it is never read as
  // whole-number grouping. In a whole-number field it must then be a plain
  // decimal multiplier (WHOLE_NUMBER_DECIMAL_FACTOR) when it has a separator,
  // and that separator cannot be the currency's thousands delimiter.
  const isFactor = (i) => /[*/]/.test(`${tokens[2 * i - 1] ?? ""}${tokens[2 * i + 1] ?? ""}`)
  const isUnclearFactor = (t, i) => {
    const unsigned = t.trim().replace(/^[+-]/, "")
    if (!isFactor(i) || !/[.,]/.test(unsigned)) return false
    if (/^[.,]$/.test(options.delimiter ?? "") && unsigned.includes(options.delimiter)) return true
    return !WHOLE_NUMBER_DECIMAL_FACTOR.test(unsigned)
  }
  if (options.precision === 0 && numberTokens.some(isUnclearFactor)) return null
  const numbers = numberTokens.map((t, i) =>
    parseTypedNumber(t.trim(), isFactor(i) ? { ...options, precision: undefined } : options),
  )
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
// Rounds to 15 significant digits when that only drops float drift (0.1 +
// 0.2, a few units in the last place) and keeps the 16th and 17th digit
// otherwise, so a large amount keeps its cents (12345678901234.25) and a
// tiny exchange rate to BTC (3.8e-10) keeps its digits. Never falls back to
// exponential notation.
export function formatUnroundedAmount(amount) {
  if (amount === 0 || !Number.isFinite(amount)) return amount.toFixed(0)

  const integerDigits = Math.floor(Math.log10(Math.abs(amount))) + 1
  const decimals = Math.min(20, Math.max(0, 15 - integerDigits))
  const driftTolerance = Math.abs(amount) * Number.EPSILON * 4
  let fixed = amount.toFixed(decimals)
  for (let extra = 1; extra <= 2 && Math.abs(Number(fixed) - amount) > driftTolerance; extra++) {
    fixed = amount.toFixed(Math.min(20, decimals + extra))
  }
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

// Derives a decimal-places count from an <input step="..."> attribute (e.g.
// "0.01" -> 2, "1" -> 0, "0.25" -> 2). BTC's step arrives as "1.0e-08", so
// this reads the step's own decimal representation (via toString, including
// its exponent) rather than deriving a power-of-ten count from -log10 —
// log10(0.25) isn't a whole number, so that approach rounded a 0.25 step
// down to 1 decimal place and truncated "1.25" to "1.3". Returns null for
// step="any" (or any other non-positive/non-finite step), matching the
// step="any" fields (trade amount, price, fee) that want an unrounded value
// rather than being truncated to a default that would drop a sub-cent
// crypto price to "0.00". Shared by money_field_controller (its own
// precision-value override takes priority over this) and goal_form_controller
// (which has no such override, only the rendered field's step).
export function precisionFromStep(step) {
  const parsed = Number(step)
  if (!Number.isFinite(parsed) || parsed <= 0) return null

  const [coefficient, exponentText = "0"] = parsed.toString().split("e")
  const [, fraction = ""] = coefficient.split(".")
  return Math.max(0, fraction.length - Number(exponentText))
}

// The money field is a plain text input, so the browser no longer enforces
// the min/max the old type="number" field carried (e.g. min: 0 on a trade's
// price and fee). Checked against the amount as it will be submitted — i.e.
// after rounding to the field's precision — so "0.001" on a 2-decimal field
// with min 0.01 is caught, since it would be submitted as "0.00". Returns
// "min" or "max" for the bound that is violated, or null when the amount is
// within bounds (a missing/non-finite bound is not enforced).
export function amountBoundViolation(amount, { min, max, precision = null } = {}) {
  const submitted = precision === null ? amount : Number(amount.toFixed(precision))
  if (Number.isFinite(min) && submitted < min) return "min"
  if (Number.isFinite(max) && submitted > max) return "max"
  return null
}
