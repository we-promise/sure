module Money::Formatting
  include ActiveSupport::NumberHelper

  # Locale groups by formatting pattern
  # European style: dot as thousands delimiter, comma as decimal separator, symbol after number
  EUROPEAN_SYMBOL_AFTER = %i[de es it tr ca ro pt-PT].freeze
  # Scandinavian/Eastern European: space as thousands delimiter, comma as decimal separator, symbol after number
  SPACE_DELIMITER_SYMBOL_AFTER = %i[pl nb hu].freeze
  # European style: dot as thousands delimiter, comma as decimal separator, symbol before number
  EUROPEAN_SYMBOL_BEFORE = %i[nl pt-BR].freeze

  FAST_FORMAT_KEYS = %i[unit precision delimiter separator format].freeze
  DELIMITER_REGEX = /(\d)(?=(\d\d\d)+(?!\d))/

  def format(options = {})
    locale = options[:locale] || I18n.locale
    opts = format_options(locale).merge(options.except(:locale))

    fast_format(opts) || number_to_currency(amount, opts)
  end
  alias_method :to_s, :format

  def format_options(locale = nil)
    local_option_overrides = locale_options(locale)

    {
      unit: get_symbol,
      precision: currency.default_precision,
      delimiter: currency.delimiter,
      separator: currency.separator,
      format: currency.default_format
    }.merge(local_option_overrides)
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
