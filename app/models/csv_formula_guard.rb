# Neutralizes spreadsheet formula injection in exported CSV text cells.
#
# Excel, LibreOffice and Google Sheets evaluate a cell that starts with `=`, `+`,
# `-`, `@`, tab, carriage return or line feed as a formula. {.escape} prefixes such
# text with a single quote (the OWASP-recommended mitigation) so it is shown as
# plain text.
#
# The guard is one-way: importers do not strip the quote, because a CSV does not say
# whether Sure wrote it, and stripping a quote from foreign data would silently
# rewrite names (and could make a rule import overwrite another rule). To keep the
# mapping injective, values that already start with apostrophes before a trigger
# character get one more, so `=x` and `'=x` export as `'=x` and `''=x` and never
# collide.
#
# Only apply this to free-text columns. Numeric and date columns must stay
# unescaped, otherwise a negative amount like `-12.50` would turn into text.
module CsvFormulaGuard
  FORMULA_PREFIX = /\A'*[=+\-@\t\r\n]/

  module_function

  def escape(value)
    return value unless value.is_a?(String) && value.match?(FORMULA_PREFIX)

    "'#{value}"
  end
end
