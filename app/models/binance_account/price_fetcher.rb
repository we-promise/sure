# frozen_string_literal: true

# Binance stablecoin quote pairs are treated as USD by both valuation paths.
class BinanceAccount::PriceFetcher
  QUOTES = %w[USDT BUSD FDUSD].freeze

  def self.fetch(symbol, provider:)
    return 1.to_d if BinanceAccount::STABLECOINS.include?(symbol)
    return nil unless provider

    QUOTES.each do |quote|
      begin
        price = BigDecimal(provider.get_spot_price("#{symbol}#{quote}").to_s)
        return price if price.finite? && price.positive?
      rescue StandardError => e
        Rails.logger.warn "BinanceAccount::PriceFetcher - no usable price for #{symbol}#{quote}: #{e.message}"
      end
    end

    nil
  end
end
