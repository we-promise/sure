class Provider::GoldApi < Provider
  Error = Class.new(Provider::Error)

  Price = Struct.new(:date, :currency, :price_per_troy_ounce, :symbol, keyword_init: true)

  def initialize(api_key)
    @api_key = api_key
  end

  def fetch_bullion_price(symbol:, currency:)
    with_provider_response do
      currency = currency.to_s.upcase
      raise Error, "A three-letter quote currency is required" unless currency.match?(/\A[A-Z]{3}\z/)

      raise Error, "An unsupported bullion symbol was requested" unless %w[XAU XAG XPT XPD].include?(symbol)
      response = client.get("/api/price/#{symbol}/#{currency}") do |request|
        request.headers["x-access-token"] = @api_key
      end
      body = JSON.parse(response.body)

      price = body["price"].to_d
      raise Error, "GoldAPI returned no #{symbol} price" unless price.positive?

      timestamp = body["timestamp"].presence
      date = timestamp ? Time.zone.at(timestamp.to_i).to_date : Date.current
      Price.new(date:, currency:, price_per_troy_ounce: price, symbol: symbol)
    end
  end

  def fetch_gold_price(currency:)
    fetch_bullion_price(symbol: "XAU", currency:)
  end

  private
    def client
      @client ||= Faraday.new(url: "https://www.goldapi.io") do |faraday|
        faraday.options.open_timeout = 5
        faraday.options.timeout = 20
      end
    end
end
