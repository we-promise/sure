# frozen_string_literal: true

# Prices Binance assets in USD. A live quote wins; during an outage the newest
# dated quote already known is reused, so a held asset is not valued at zero.
# Quotes keep the date they were observed on: a reused quote must not look
# fresher than it is when compared with another source later.
class BinanceAccount::AssetPricer
  QUOTE_CURRENCIES = %w[USDT BUSD FDUSD].freeze

  # @param previous_quotes [Hash] quotes stored by an earlier sync, keyed by symbol
  def initialize(provider, previous_quotes: {})
    @provider = provider
    @previous_quotes = previous_quotes.to_h
    @live_prices = {}
  end

  # @return [Hash, nil] { "price_usd" => String, "date" => "YYYY-MM-DD" }
  def quote(symbol, security: nil)
    live = live_price_usd(symbol)
    return build_quote(live, Date.current) if live

    candidates = [ previous_quote(symbol), stored_quote(security || find_security(symbol)) ]
    candidates.compact.max_by { |candidate| candidate["date"] }
  end

  def live_price_usd(symbol)
    return 1.to_d if BinanceAccount::STABLECOINS.include?(symbol)
    return @live_prices[symbol] if @live_prices.key?(symbol)

    @live_prices[symbol] = fetch_live_price(symbol)
  end

  # Newest positive stored price of the security, converted to USD on its own date.
  def stored_quote(security)
    return unless security

    price = security.prices.where("price > 0 AND date <= ?", Date.current).order(date: :desc).first
    return unless price

    build_quote(Money.new(price.price, price.currency).exchange_to("USD", date: price.date).amount, price.date)
  rescue Money::ConversionError, Money::Currency::UnknownCurrencyError
    nil
  end

  private

    attr_reader :provider

    def fetch_live_price(symbol)
      return unless provider

      QUOTE_CURRENCIES.each do |quote|
        price = provider.get_spot_price("#{symbol}#{quote}")
        return price.to_d if price.present? && price.to_d.positive?
      end

      Rails.logger.warn "BinanceAccount::AssetPricer - no price found for #{symbol} across all quote pairs"
      nil
    end

    def previous_quote(symbol)
      quote = @previous_quotes[symbol]
      return unless quote.is_a?(Hash) && quote["price_usd"].to_d.positive? && quote["date"].present?

      quote.slice("price_usd", "date")
    end

    def find_security(symbol)
      Security.find_by(ticker: "#{Onchain::SecurityResolver::TICKER_PREFIX}#{symbol.to_s.upcase}")
    end

    def build_quote(price_usd, date)
      { "price_usd" => price_usd.to_d.to_s("F"), "date" => date.to_date.iso8601 }
    end
end
