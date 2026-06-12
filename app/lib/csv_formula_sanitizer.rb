# frozen_string_literal: true

module CsvFormulaSanitizer
  FORMULA_PREFIX = /\A[=+\-@\t\r]/

  module_function

  def escape(value)
    string = value.to_s
    return string unless string.match?(FORMULA_PREFIX)

    "'#{string}"
  end
end
