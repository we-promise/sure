module SharesightAccount::DataHelpers
  extend ActiveSupport::Concern
  include CurrencyNormalizable

  # Sharesight market codes (plus a few aliases broker imports use) to MICs.
  # Anything not in here gets an offline security, because searching a price
  # provider could pick up the same ticker on a different exchange.
  MARKET_MICS = {
    "ASX" => "XASX",
    "NZX" => "XNZE",
    "NYSE" => "XNYS",
    "NASDAQ" => "XNAS",
    "ARCA" => "ARCX",
    "NYSE_ARCA" => "ARCX",
    "NYSEARCA" => "ARCX",
    "AMEX" => "XASE",
    "NYSE_AMERICAN" => "XASE",
    "BATS" => "BATS",
    "LSE" => "XLON",
    "TSX" => "XTSE",
    "TSXV" => "XTSX",
    "HKG" => "XHKG",
    "HKEX" => "XHKG",
    "SGX" => "XSES",
    "XETRA" => "XETR",
    "FWB" => "XFRA",
    "EPA" => "XPAR",
    "AMS" => "XAMS",
    "SIX" => "XSWX",
    "TYO" => "XJPX"
  }.freeze

  # The currency each exchange trades in, for trades whose holding doesn't say.
  MIC_CURRENCIES = {
    "XASX" => "AUD", "XNZE" => "NZD", "XNYS" => "USD", "XNAS" => "USD", "ARCX" => "USD",
    "XASE" => "USD", "BATS" => "USD", "XLON" => "GBP", "XTSE" => "CAD", "XTSX" => "CAD",
    "XHKG" => "HKD", "XSES" => "SGD", "XETR" => "EUR", "XFRA" => "EUR", "XPAR" => "EUR",
    "XAMS" => "EUR", "XSWX" => "CHF", "XJPX" => "JPY"
  }.freeze

  private

    def parse_decimal(value)
      return nil if value.nil?

      normalized = value.is_a?(String) ? value.strip : value.to_s
      return nil if normalized.blank?

      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end

    # Sharesight dates are ISO 8601, except the portfolio's inception date,
    # which can look like "03 Feb 2021".
    def parse_date(value)
      return nil if value.blank?
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def market_mic(market_code)
      MARKET_MICS[market_code.to_s.strip.upcase]
    end

    def market_currency(market_code)
      MIC_CURRENCIES[market_mic(market_code)]
    end

    def resolve_security(symbol, market_code, name = nil)
      ticker = symbol.to_s.strip.upcase
      return nil if ticker.blank?

      mic = market_mic(market_code)
      security = if mic
        begin
          Security::Resolver.new(ticker, exchange_operating_mic: mic).resolve
        rescue => e
          Rails.logger.warn("SharesightAccount: resolving #{ticker}|#{mic} failed (#{e.class}: #{e.message}); using an offline security")
          nil
        end
      end
      security ||= offline_security(ticker, mic)

      security.update!(name: name) if name.present? && security.name.blank?
      security
    end

    def offline_security(ticker, mic)
      Security.find_or_initialize_by_ticker_and_exchange(ticker: ticker, exchange_operating_mic: mic).tap do |security|
        security.offline = true if security.new_record?
        security.save! if security.changed?
      end
    rescue ActiveRecord::RecordNotUnique
      Security.find_by_ticker_and_exchange(ticker: ticker, exchange_operating_mic: mic)
    end
end
