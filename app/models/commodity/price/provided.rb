# Commodity price sources, neither of which needs an API key:
# - gold-api.com for today's spot price;
# - Yahoo Finance front-month futures for history (e.g. backfilling from an
#   older purchase date) and as a fallback when gold-api.com is unavailable.
# Yahoo's HTTP client is reused, but results are mapped into commodity
# prices — no Security records are created.
module Commodity::Price::Provided
  extend ActiveSupport::Concern

  ProviderPrice = Data.define(:code, :date, :price, :currency, :source)

  class_methods do
    def spot_provider
      Provider::Registry.get_provider(:gold_api)
    end

    def futures_provider
      Provider::Registry.get_provider(:yahoo_finance)
    end

    # Returns { code => [ProviderPrice, ...] } for the given Commodity::Metal
    # list. Where both sources report the same day, spot wins.
    def fetch_provider_prices(metals, start_date:, end_date:)
      futures = futures_prices(metals, start_date:, end_date:)
      spot = spot_prices(metals, start_date:, end_date:)

      metals.to_h do |metal|
        by_date = futures.fetch(metal.code, []).index_by(&:date)
        spot.fetch(metal.code, []).each { |price| by_date[price.date] = price }
        [ metal.code, by_date.values.sort_by(&:date) ]
      end
    end

    def import_provider_prices(start_date:, end_date: Date.current, codes: nil, clear_cache: false)
      metals = Commodity.metals
      metals = metals.select { |m| codes.include?(m.code) } if codes
      return 0 if metals.empty? || start_date.nil?

      Commodity::Price::Importer.new(metals: metals, start_date: start_date, end_date: end_date, clear_cache: clear_cache).import
    end

    private
      # Spot is only available for "now", so it is used when the range includes today.
      def spot_prices(metals, start_date:, end_date:)
        return {} unless end_date >= Date.current.in_time_zone("America/New_York").to_date

        provider = spot_provider
        by_symbol = metals.index_by(&:gold_api_symbol)
        response = provider.fetch_current_prices(symbols: by_symbol.keys)

        unless response.success?
          capture_fetch_error(provider, response.error.message, start_date:, end_date:)
          return {}
        end

        response.data
          .select { |p| (start_date..end_date).cover?(p.date) }
          .map { |p| ProviderPrice.new(code: by_symbol.fetch(p.symbol).code, date: p.date, price: p.price, currency: p.currency, source: "gold_api") }
          .group_by(&:code)
      end

      def futures_prices(metals, start_date:, end_date:)
        provider = futures_provider

        metals.to_h do |metal|
          response = provider.fetch_security_prices(symbol: metal.yahoo_symbol, exchange_operating_mic: nil, start_date: start_date, end_date: end_date)

          prices = if response.success?
            response.data.map do |p|
              ProviderPrice.new(code: metal.code, date: p.date, price: p.price, currency: p.currency.presence || "USD", source: "yahoo_futures")
            end
          else
            capture_fetch_error(provider, response.error.message, start_date:, end_date:, symbol: metal.yahoo_symbol)
            []
          end

          [ metal.code, prices ]
        end
      end

      def capture_fetch_error(provider, message, **metadata)
        DebugLogEntry.capture(
          category: "commodity_price_fetch",
          level: "warn",
          message: "Could not fetch commodity prices",
          source: name,
          provider: provider,
          metadata: metadata.merge(provider_error: message)
        )
      end
  end
end
