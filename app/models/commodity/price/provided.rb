# Chooses the commodity price source: the keyed spot provider (metalpriceapi)
# when configured, otherwise Yahoo Finance front-month futures as an
# approximation of spot. Yahoo's HTTP client is reused, but results are mapped
# into commodity prices — no Security records are created.
module Commodity::Price::Provided
  extend ActiveSupport::Concern

  ProviderPrice = Data.define(:code, :date, :price, :currency, :source)

  class_methods do
    def spot_provider
      Provider::Registry.get_provider(:metal_price_api)
    end

    def futures_provider
      Provider::Registry.get_provider(:yahoo_finance)
    end

    # Returns { code => [ProviderPrice, ...] } for the given Commodity::Metal list.
    def fetch_provider_prices(metals, start_date:, end_date:)
      spot_prices(metals, start_date:, end_date:) || futures_prices(metals, start_date:, end_date:)
    end

    def import_provider_prices(start_date:, end_date: Date.current, codes: nil, clear_cache: false)
      metals = Commodity.metals
      metals = metals.select { |m| codes.include?(m.code) } if codes
      return 0 if metals.empty? || start_date.nil?

      Commodity::Price::Importer.new(metals: metals, start_date: start_date, end_date: end_date, clear_cache: clear_cache).import
    end

    private
      def spot_prices(metals, start_date:, end_date:)
        provider = spot_provider
        return nil unless provider

        by_symbol = metals.index_by(&:metal_price_api_symbol)
        response = provider.fetch_commodity_prices(symbols: by_symbol.keys, start_date: start_date, end_date: end_date)

        unless response.success?
          capture_fetch_error(provider, response.error.message, start_date:, end_date:)
          return nil
        end

        prices = response.data.map do |p|
          ProviderPrice.new(code: by_symbol.fetch(p.symbol).code, date: p.date, price: p.price, currency: p.currency, source: "metal_price_api")
        end
        metals.to_h { |m| [ m.code, [] ] }.merge(prices.group_by(&:code))
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
