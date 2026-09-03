class Provider::GoldApi < Provider
  Error = Class.new(Provider::Error)

  Price = Data.define(:date, :currency, :price_per_troy_ounce)

  def initialize(api_key)
    @api_key = api_key
  end

  def fetch_gold_price(currency:)
    with_provider_response do
      currency = currency.to_s.upcase
      raise Error, "A three-letter quote currency is required" unless currency.match?(/\A[A-Z]{3}\z/)

      response = client.get("/api/price/XAU/#{currency}") do |request|
        request.headers["x-access-token"] = @api_key
      end
      body = JSON.parse(response.body)

      price = body["price"].to_d
      raise Error, "GoldAPI returned no gold price" unless price.positive?

      timestamp = body["timestamp"].presence
      date = timestamp ? Time.zone.at(timestamp.to_i).to_date : Date.current
      Price.new(date:, currency:, price_per_troy_ounce: price)
    end
  end

  private
    def client
      @client ||= Faraday.new(url: "https://www.goldapi.io") do |faraday|
        faraday.options.open_timeout = 5
        faraday.options.timeout = 20
      end
    end
end
