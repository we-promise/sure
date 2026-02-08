module Money::Formatting
  include ActiveSupport::NumberHelper

  # Locale groups by formatting pattern
  # European style: dot as thousands delimiter, comma as decimal separator, symbol after number
  EUROPEAN_SYMBOL_AFTER = %i[de es it tr ca ro].freeze
  # Scandinavian/Eastern European: space as thousands delimiter, comma as decimal separator, symbol after number
  SPACE_DELIMITER_SYMBOL_AFTER = %i[pl nb].freeze
  # European style: dot as thousands delimiter, comma as decimal separator, symbol before number
  EUROPEAN_SYMBOL_BEFORE = %i[nl pt-BR].freeze

  def format(options = {})
    locale = options[:locale] || I18n.locale
    default_opts = format_options(locale)

    number_to_currency(amount, default_opts.merge(options))
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
    def get_symbol
      if currency.symbol == "$" && currency.iso_code != "USD"
        [ currency.iso_code.first(2), currency.symbol ].join
      else
        currency.symbol
      end
    end

    def locale_options(locale)
      locale_sym = (locale || I18n.locale || :en).to_sym

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
