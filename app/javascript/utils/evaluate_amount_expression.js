import parseLocaleFloat from "utils/parse_locale_float"

// Only +, -, *, / are treated as operators; commas and dots always belong to
// a number (as a decimal or thousands separator), so tokenizing on these four
// characters is unambiguous.
const OPERATOR = /[+\-*/]/

// A valid number token: an optional sign, then a digit, then any run of
// digits/dot/comma/space (grouping space, matching parseLocaleFloat's
// tolerance). Anything else (letters, an empty token, a bare sign) is not a
// number, so the whole input is rejected rather than silently parsed to 0.
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

// Parses a money field's raw text as a single locale-formatted amount, or as
// a simple arithmetic expression over such amounts (e.g. "12,50 + 4,30" or
// "100/3"), evaluated left to right with the usual * / before + - precedence.
// Returns a finite number, or null when the text isn't a valid amount or
// expression (so the caller can leave the field untouched instead of
// overwriting a typo with 0).
export default function evaluateAmountExpression(value, options = {}) {
  if (typeof value !== "string") return null

  const trimmed = value.trim()
  if (trimmed === "") return null

  const tokens = tokenize(trimmed)
  if (tokens === null) return null

  const numberTokens = tokens.filter((_, i) => i % 2 === 0)
  const operatorTokens = tokens.filter((_, i) => i % 2 === 1)

  if (numberTokens.some((t) => !NUMBER.test(t.trim()))) return null

  const numbers = numberTokens.map((t) => parseLocaleFloat(t.trim(), options))

  if (operatorTokens.length === 0) {
    const result = numbers[0]
    return Number.isFinite(result) ? result : null
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
