# Spot prices for precious metals from metalpriceapi.com.
# Prices are returned per troy ounce in USD (the `USD<code>` rate keys).
class Provider::MetalPriceApi < Provider
  extend SslConfigurable

  Error = Class.new(Provider::Error)

  Price = Data.define(:symbol, :date, :price, :currency)

  # The timeframe endpoint accepts at most 365 days per request.
  MAX_TIMEFRAME_DAYS = 365

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  def fetch_commodity_prices(symbols:, start_date:, end_date:)
    with_provider_response do
      chunks(start_date, end_date).flat_map do |from, to|
        parse_timeframe(get_json("/v1/timeframe", start_date: from.iso8601, end_date: to.iso8601, base: "USD", currencies: symbols.join(",")), symbols)
      end
    end
  end

  private
    attr_reader :api_key

    def base_url
      ENV["METAL_PRICE_API_URL"].presence || "https://api.metalpriceapi.com"
    end

    def chunks(start_date, end_date)
      ranges = []
      from = start_date
      while from <= end_date
        to = [ from + (MAX_TIMEFRAME_DAYS - 1).days, end_date ].min
        ranges << [ from, to ]
        from = to + 1.day
      end
      ranges
    end

    def parse_timeframe(body, symbols)
      body.fetch("rates", {}).flat_map do |date, rates|
        symbols.filter_map do |symbol|
          price = rates["USD#{symbol}"]
          next unless price.present? && price.to_d.positive?

          Price.new(symbol: symbol, date: Date.parse(date), price: price.to_d, currency: "USD")
        end
      end
    end

    def get_json(path, params)
      response = client.get(path, params)
      body = JSON.parse(response.body)
      unless body["success"]
        raise Error.new(body.dig("error", "info") || "metalpriceapi request failed", details: body["error"])
      end
      body
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, { max: 2, interval: 1.0, backoff_factor: 2 })
        faraday.response :raise_error
        faraday.headers["X-API-KEY"] = api_key
        faraday.options.timeout = 15
      end
    end
end
