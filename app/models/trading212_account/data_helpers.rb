module Trading212Account::DataHelpers
  extend ActiveSupport::Concern

  private

    def parse_decimal(value)
      return nil if value.nil?

      normalized = value.is_a?(String) ? value.strip : value.to_s
      return nil if normalized.blank?

      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      return nil if value.blank?

      case value
      when Date
        value
      when Time, DateTime, ActiveSupport::TimeWithZone
        value.to_date
      else
        Time.zone.parse(value.to_s)&.to_date || Date.parse(value.to_s)
      end
    rescue ArgumentError, TypeError
      nil
    end

    # T212 tickers look like "AAPL_US_EQ". Derive a standard ticker by taking
    # the first segment, which is the instrument symbol on its primary exchange.
    def standard_ticker(t212_ticker)
      t212_ticker.to_s.split("_").first.upcase
    end

    def resolve_security_for_ticker(t212_ticker)
      instrument = instruments_map[t212_ticker]

      if instrument
        resolve_security_from_instrument(instrument, t212_ticker)
      else
        ticker = standard_ticker(t212_ticker)
        Security.find_by(ticker: ticker) || Security.create!(ticker: ticker, name: ticker)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      ticker = standard_ticker(t212_ticker)
      Security.find_by(ticker: ticker)
    end

    def resolve_security_from_instrument(instrument, t212_ticker)
      ticker = standard_ticker(t212_ticker)
      name = instrument["shortName"].presence || ticker

      Security.find_by(ticker: ticker) ||
        Security.create!(ticker: ticker, name: name)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end

    # Resolve (or create) a Security when we already have isin/ticker/name in hand,
    # e.g. from the nested instrument object in positions and orders responses.
    # Note: the securities table has no isin column; isin is accepted but unused.
    def resolve_security_direct(isin, ticker, name)
      Security.find_by(ticker: ticker) ||
        Security.create!(ticker: ticker, name: name)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end

    def instrument_currency(t212_ticker)
      instrument = instruments_map[t212_ticker]
      instrument&.dig("currencyCode").presence || currency
    end
end
