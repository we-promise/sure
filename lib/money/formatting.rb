module Money::Formatting
  include ActiveSupport::NumberHelper

  # Locale groups by formatting pattern
  # European style: dot as thousands delimiter, comma as decimal separator, symbol after number
  EUROPEAN_SYMBOL_AFTER = %i[de es it tr ca ro pt-PT].freeze
  # Scandinavian/Eastern European: space as thousands delimiter, comma as decimal separator, symbol after number
  SPACE_DELIMITER_SYMBOL_AFTER = %i[pl nb hu].freeze
  # European style: dot as thousands delimiter, comma as decimal separator, symbol before number
  EUROPEAN_SYMBOL_BEFORE = %i[nl pt-BR].freeze
  # Currencies and locales that use the South Asian numbering system (lakh/crore).
  # Grouping is decided once in #format_options so every caller (web, exports,
  # API formatted strings) agrees on it.
  INDIAN_GROUPING_CURRENCIES = %w[INR].freeze
  INDIAN_LOCALES = %i[en-IN en-IND hi hi-IN mr-IN ta te bn gu kn ml pa].freeze
  INDIAN_DELIMITER_PATTERN = /(\d+?)(?=(\d\d)+(\d)(?!\d))/.freeze

  FAST_FORMAT_KEYS = %i[unit precision delimiter separator format].freeze
  DELIMITER_REGEX = /(\d)(?=(\d\d\d)+(?!\d))/

  def format(options = {})
    options = options.dup
    requested_locale = options.delete(:locale)
    locale = requested_locale || I18n.locale
    indian_grouping = options.delete(:indian_grouping)
    opts = format_options(locale, indian_grouping: indian_grouping).merge(options)

    # Rails resolves number.format settings (strip_insignificant_zeros, ...)
    # from the locale passed to number_to_currency. Bypass the fast path when
    # the caller asked for a locale other than the active one so those settings
    # come from the requested locale.
    explicit_locale = requested_locale.present? && requested_locale.to_sym != I18n.locale.to_sym
    fast = fast_format(opts) unless explicit_locale
    return fast if fast

    slow_opts = opts.merge(locale: locale)
    # When the caller asked for a different locale, keep money at decimal
    # precision instead of letting a locale such as hu round to significant
    # digits. The ambient path keeps number_to_currency parity.
    slow_opts[:significant] = false if explicit_locale
    number_to_currency(amount, slow_opts)
  end
  alias_method :to_s, :format

  def format_options(locale = nil, indian_grouping: nil)
    opts = {
      unit: get_symbol,
      precision: currency.default_precision,
      delimiter: currency.delimiter,
      separator: currency.separator,
      format: currency.default_format
    }.merge(locale_options(locale))

    indian = indian_grouping?(locale, indian_grouping)
    opts[:delimiter_pattern] = INDIAN_DELIMITER_PATTERN if indian

    # Indian grouping and Indian locales always use Indian punctuation. A
    # currency's own separators can otherwise produce mixed output such as
    # "€12.34.567,00" or "12 34 567,00 €".
    if indian || indian_locale?(locale)
      opts[:delimiter] = ","
      opts[:separator] = "."
    end

    opts
  end

  private
    # number_to_currency resolves its options (several I18n lookups and merges) once per
    # converter on every call. For the options built above this gives the same string;
    # nil leaves the rest (significant digits, stripped zeros, custom keys) to it.
    def fast_format(opts)
      precision, format, unit = opts.values_at(:precision, :format, :unit)
      return unless (opts.keys - FAST_FORMAT_KEYS).empty? && precision.is_a?(Integer) && precision >= 0 &&
        format.is_a?(String) && unit.is_a?(String) && amount.finite?

      number_i18n = I18n.translate(:"number.format", default: {})
      currency_i18n = number_i18n.merge(I18n.translate(:"number.currency.format", default: {}))
      return if currency_i18n[:significant] || currency_i18n[:strip_insignificant_zeros]

      precision_i18n = number_i18n.merge(I18n.translate(:"number.precision.format", default: {}))
      return if currency_i18n.key?(:delimiter_pattern) || precision_i18n.key?(:delimiter_pattern)

      round_mode = currency_i18n.fetch(:round_mode) { precision_i18n.fetch(:round_mode, :default) }

      number = amount
      if number.negative?
        number = number.abs
        format = "-#{format}" if number * 10**precision >= 0.5
      end

      rounded = number.round(precision, round_mode.to_sym)
      whole, fraction = rounded.abs.to_s("F").split(".", 2)
      whole = whole.gsub(DELIMITER_REGEX) { "#{$1}#{opts[:delimiter]}" }
      number_s = precision.zero? ? whole : "#{whole}#{opts[:separator]}#{(fraction + "0" * precision)[0, precision]}"

      format.gsub("%n", number_s).gsub("%u", unit)
    end

    # Explicit :indian_grouping wins; otherwise Indian grouping follows the
    # currency (INR) or the active locale.
    def indian_grouping?(locale, override)
      return override unless override.nil?

      INDIAN_GROUPING_CURRENCIES.include?(currency.iso_code) || indian_locale?(locale)
    end

    def indian_locale?(locale)
      INDIAN_LOCALES.include?((locale || I18n.locale || :en).to_sym)
    end

    def get_symbol
      if currency.symbol == "$" && currency.iso_code != "USD"
        [ currency.iso_code.first(2), currency.symbol ].join
      else
        currency.symbol
      end
    end

    def locale_options(locale)
      locale_sym = (locale || I18n.locale || :en).to_sym

      return { format: "%n %u" } if currency.iso_code == "MXN" && locale_sym == :es

      # French locale: uses non-breaking spaces (unique formatting)
      if locale_sym == :fr
        return { delimiter: "\u00A0", separator: ",", format: "%n\u00A0%u" }
      end

      # European style: dot delimiter, comma separator, symbol after number
      if EUROPEAN_SYMBOL_AFTER.include?(locale_sym)
        return { delimiter: ".", separator: ",", format: "%n %u" }
      end

      # Space delimiter, comma separator, symbol after number
      if SPACE_DELIMITER_SYMBOL_AFTER.include?(locale_sym)
        return { delimiter: " ", separator: ",", format: "%n %u" }
      end

      # European style: dot delimiter, comma separator, symbol before number
      if EUROPEAN_SYMBOL_BEFORE.include?(locale_sym)
        return { delimiter: ".", separator: ",", format: "%u %n" }
      end

      # Currency-specific overrides for remaining locales
      case [ currency.iso_code, locale_sym ]
      when [ "EUR", :pt ]
        { delimiter: ".", separator: ",", format: "%u %n" }
      when [ "EUR", :en ], [ "EUR", :en_IE ]
        { delimiter: ",", separator: "." }
      else
        {}
      end
    end
end
