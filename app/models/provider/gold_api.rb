# Current precious-metal spot prices from gold-api.com. The current-price
# endpoint is free and needs no API key; historical endpoints need a key and
# are not used (history comes from Yahoo Finance futures instead).
class Provider::GoldApi < Provider
  extend SslConfigurable

  Error = Class.new(Provider::Error)

  Price = Data.define(:symbol, :date, :price, :currency)

  # Latest spot price per troy ounce in USD for each symbol (e.g. XAU, XAG).
  def fetch_current_prices(symbols:)
    with_provider_response do
      symbols.map do |symbol|
        body = JSON.parse(client.get("/price/#{symbol}").body)
        price = body["price"].to_d
        raise Error, "No price for #{symbol}" unless price.positive?

        Price.new(
          symbol: symbol,
          date: Time.iso8601(body.fetch("updatedAt")).in_time_zone("America/New_York").to_date,
          price: price,
          currency: body["currency"].presence || "USD"
        )
      end
    end
  end

  private
    def base_url
      ENV["GOLD_API_URL"].presence || "https://api.gold-api.com"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, { max: 2, interval: 0.5, backoff_factor: 2 })
        faraday.response :raise_error
        faraday.options.timeout = 10
      end
    end
end
