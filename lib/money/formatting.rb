module Money::Formatting
  include ActiveSupport::NumberHelper

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

      # French locale: symbol after number with non-breaking space, comma as decimal separator
      if locale_sym == :fr
        return { delimiter: "\u00A0", separator: ",", format: "%n\u00A0%u" }
      end

      # German locale: symbol after number with space, comma as decimal separator
      if locale_sym == :de
        return { delimiter: ".", separator: ",", format: "%n %u" }
      end

      # Spanish locale: symbol after number with space, comma as decimal separator
      if locale_sym == :es
        return { delimiter: ".", separator: ",", format: "%n %u" }
      end

      # Italian locale: symbol after number with space, comma as decimal separator
      if locale_sym == :it
        return { delimiter: ".", separator: ",", format: "%n %u" }
      end

      # Polish locale: symbol after number with space, comma as decimal separator, space as thousands delimiter
      if locale_sym == :pl
        return { delimiter: " ", separator: ",", format: "%n %u" }
      end

      # Portuguese (Brazil) locale: symbol before, comma as decimal separator
      if locale_sym == :"pt-BR"
        return { delimiter: ".", separator: ",", format: "%u %n" }
      end

      # Turkish locale: symbol after number with space, comma as decimal separator
      if locale_sym == :tr
        return { delimiter: ".", separator: ",", format: "%n %u" }
      end

      # Norwegian Bokmål locale: symbol after number with space, comma as decimal separator, space as thousands delimiter
      if locale_sym == :nb
        return { delimiter: " ", separator: ",", format: "%n %u" }
      end

      # Catalan locale: symbol after number with space, comma as decimal separator
      if locale_sym == :ca
        return { delimiter: ".", separator: ",", format: "%n %u" }
      end

      # Romanian locale: symbol after number with space, comma as decimal separator
      if locale_sym == :ro
        return { delimiter: ".", separator: ",", format: "%n %u" }
      end

      # Dutch locale: symbol before number with space, comma as decimal separator
      if locale_sym == :nl
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
