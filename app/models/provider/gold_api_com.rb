# Keyless spot prices from gold-api.com (not goldapi.io, see Provider::GoldApi).
# The current-price endpoint is free, needs no API key and quotes USD only.
class Provider::GoldApiCom < Provider
  extend SslConfigurable

  Error = Class.new(Provider::Error)

  def fetch_bullion_price(symbol:)
    with_provider_response do
      raise Error, "An unsupported bullion symbol was requested" unless %w[XAU XAG XPT XPD].include?(symbol)

      body = JSON.parse(client.get("/price/#{symbol}").body)
      price = body["price"].to_d
      raise Error, "gold-api.com returned no #{symbol} price" unless price.positive?

      updated_at = body["updatedAt"].presence
      raise Error, "gold-api.com returned no #{symbol} timestamp" unless updated_at

      Provider::GoldApi::Price.new(date: Time.iso8601(updated_at).in_time_zone.to_date, currency: "USD", price_per_troy_ounce: price, symbol: symbol)
    end
  end

  private
    def client
      @client ||= Faraday.new(url: ENV["GOLD_API_COM_URL"].presence || "https://api.gold-api.com", ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.options.open_timeout = 5
        faraday.options.timeout = 20
        faraday.response :raise_error
      end
    end
end
