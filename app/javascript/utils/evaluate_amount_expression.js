// Only +, -, *, / are treated as operators; commas and dots always belong to
// a number (as a decimal or thousands separator), so tokenizing on these four
// characters is unambiguous.
const OPERATOR = /[+\-*/]/

// A valid number token: an optional sign, then a digit, then any run of
// digits/dot/comma/space (grouping space). Anything else (letters, an empty
// token, a bare sign) is not a number, so the whole input is rejected rather
// than silently parsed to 0.
const NUMBER = /^[+-]?\d[\d.,\u0020\u00a0\u202f]*$/

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
// almost never adds a thousands separator, so here a single comma or a
// single dot is read as *the* decimal point regardless of how many digits
// follow it — "10,321" is ten-point-three-two-one, not ten thousand three
// hundred twenty-one. A separator is only read as grouping when it can't
// possibly be a decimal point: it appears more than once, or both a comma
// and a dot are present (the later one wins as the decimal point, the
// earlier one is grouping) — e.g. "1.234,56" and "1,234.56" both parse to
// 1234.56. An explicit `separator` hint (if ever supplied by the caller)
// still resolves a lone comma/dot deterministically, same as
// parseLocaleFloat.
function parseTypedNumber(token, { separator } = {}) {
  const negative = token.startsWith("-")
  const unsigned = token.replace(/^[+-]/, "")
  const cleaned = unsigned.replace(/[\u0020\u00a0\u202f]/g, "")

  const commaCount = (cleaned.match(/,/g) || []).length
  const dotCount = (cleaned.match(/\./g) || []).length

  let normalized
  if (separator === ",") {
    normalized = cleaned.replace(/\./g, "").replace(",", ".")
  } else if (separator === ".") {
    normalized = cleaned.replace(/,/g, "")
  } else if (commaCount > 0 && dotCount > 0) {
    const lastComma = cleaned.lastIndexOf(",")
    const lastDot = cleaned.lastIndexOf(".")
    normalized =
      lastComma > lastDot
        ? cleaned.replace(/\./g, "").replace(",", ".")
        : cleaned.replace(/,/g, "")
  } else if (commaCount > 1) {
    normalized = cleaned.replace(/,/g, "")
  } else if (commaCount === 1) {
    normalized = cleaned.replace(",", ".")
  } else if (dotCount > 1) {
    normalized = cleaned.replace(/\./g, "")
  } else {
    normalized = cleaned
  }

  const value = Number.parseFloat(normalized)
  if (!Number.isFinite(value)) return null

  return negative ? -value : value
}

// Parses a money field's raw text as a single typed amount, or as a simple
// arithmetic expression over such amounts (e.g. "12,50 + 4,30" or "100/3"),
// evaluated left to right with the usual * / before + - precedence. Returns
// a finite number, or null when the text isn't a valid amount or expression
// (so the caller can leave the field untouched instead of overwriting a typo
// with 0).
export default function evaluateAmountExpression(value, options = {}) {
  if (typeof value !== "string") return null

  const trimmed = value.trim()
  if (trimmed === "") return null

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
