# Single source of truth for CSV formula-injection defence (CWE-1236).
#
# Values starting with =, +, -, @ execute as formulas when a spreadsheet opens
# the file. \t, \r and \n are included because some parsers trim leading
# whitespace-like characters before evaluating the cell, so a tab in front of
# "=1+1" would still trigger one. Leading literal spaces are not treated as a
# bypass by mainstream parsers today; extend the character class if that
# changes.
#
# A plain signed number such as "-42.5" is left alone: it cannot run anything,
# and escaping it would turn every negative amount into text.
#
# CSV only. Never apply this to JSON or NDJSON output: it would mutate the
# user's data and break the export/import round-trip.
module CsvSanitizer
  FORMULA_TRIGGER = /\A[=+\-@\t\r\n]/
  PLAIN_NUMBER = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/

  module_function

  # Prefixes formula-triggering strings with a single quote so spreadsheets
  # render them as literal text. Non-string values pass through unchanged.
  def sanitize(value)
    return value unless value.is_a?(String) && value.match?(FORMULA_TRIGGER)

    value.match?(PLAIN_NUMBER) ? value : "'#{value}"
  end

  # Sanitizes a whole row. Prefer this over sanitizing chosen columns: picking
  # fields by hand is how new user-controlled columns end up unescaped.
  def sanitize_row(values)
    Array(values).map { |value| sanitize(value) }
  end

  # Reverses #sanitize. The exports are meant to be importable again, so the
  # CSV parser undoes the escape rather than reading it back as part of the
  # name. Only a quote followed by a formula trigger is removed, so "O'Brien"
  # and "'tis" survive, and a file written by a spreadsheet that used the same
  # convention is read the way it was meant.
  def unescape(value)
    return value unless value.is_a?(String)

    value.start_with?("'") && value[1..].match?(FORMULA_TRIGGER) ? value[1..] : value
  end
end
