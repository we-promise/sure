class Money::DisplayFormat
  GROUPING_STANDARD = "standard".freeze
  GROUPING_INDIAN = "indian".freeze

  class << self
    # Resolved number rules for a user, so API clients can render amounts
    # without inferring grouping from their own locale or country.
    def for_user(user)
      locale = user&.locale.presence || user&.family&.locale.presence || I18n.locale
      currency = user&.family&.currency || Money.default_currency
      amount_format = user&.effective_amount_format || Money::Formatting::LANGUAGE_FORMAT

      for_currency(currency, locale: locale, amount_format: amount_format)
    end

    def for_currency(currency, locale: I18n.locale, amount_format: Money::Formatting::LANGUAGE_FORMAT)
      money = Money.new(0, currency)
      options = money.format_options(locale, amount_format: amount_format)
      pattern = options[:format].presence || "%u%n"

      {
        key: amount_format.to_s,
        grouping: options[:delimiter_pattern].present? ? GROUPING_INDIAN : GROUPING_STANDARD,
        delimiter: options[:delimiter],
        separator: options[:separator],
        symbol_position: symbol_position(pattern),
        symbol_spacing: symbol_spacing(pattern)
      }
    end

    private
      def symbol_position(pattern)
        number_index = pattern.index("%n")
        unit_index = pattern.index("%u")

        return "before" if number_index.nil? || unit_index.nil?

        number_index < unit_index ? "after" : "before"
      end

      # The literal text between the symbol and the number, e.g. "%u %n" -> " ".
      def symbol_spacing(pattern)
        match = pattern.match(/%[un]([^%]*)%[un]/)
        match ? match[1] : ""
      end
  end
end
