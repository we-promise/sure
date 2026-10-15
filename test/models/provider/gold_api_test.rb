require "test_helper"

class Provider::GoldApiTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::GoldApi.new
  end

  test "fetches current spot prices without an API key" do
    stub_request(:get, "https://api.gold-api.com/price/XAU")
      .to_return(status: 200, body: { currency: "USD", name: "Gold", price: 4155.399902, symbol: "XAU", updatedAt: "2026-10-15T10:28:14Z" }.to_json)
    stub_request(:get, "https://api.gold-api.com/price/XAG")
      .to_return(status: 200, body: { currency: "USD", name: "Silver", price: 56.801998, symbol: "XAG", updatedAt: "2026-10-15T10:28:14Z" }.to_json)

    response = @provider.fetch_current_prices(symbols: %w[XAU XAG])

    assert response.success?
    assert_equal [ [ "XAU", BigDecimal("4155.399902") ], [ "XAG", BigDecimal("56.801998") ] ], response.data.map { |p| [ p.symbol, p.price ] }
    assert_equal [ Date.new(2026, 10, 15), "USD" ], [ response.data.first.date, response.data.first.currency ]
    assert_not_requested :get, /api.gold-api.com/, headers: { "x-api-key" => /.*/ }
  end

  test "returns an error response when the service is unavailable" do
    stub_request(:get, "https://api.gold-api.com/price/XAU").to_return(status: 503)

    response = @provider.fetch_current_prices(symbols: %w[XAU])

    assert_not response.success?
  end
end
