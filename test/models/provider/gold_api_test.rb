require "test_helper"

class Provider::GoldApiTest < ActiveSupport::TestCase
  test "returns the XAU price per troy ounce in the requested currency" do
    provider = Provider::GoldApi.new("test-key")
    response = Struct.new(:body).new({
      "timestamp" => Time.zone.parse("2026-09-03 12:00:00 UTC").to_i,
      "price" => 3_110.34768,
      "unit" => "troy_ounce"
    }.to_json)
    client = mock
    client.expects(:get).with("/api/price/XAU/USD").yields(Struct.new(:headers).new({})).returns(response)
    provider.stubs(:client).returns(client)

    result = provider.fetch_gold_price(currency: "usd")

    assert result.success?
    assert_equal "USD", result.data.currency
    assert_equal Date.new(2026, 9, 3), result.data.date
    assert_in_delta 3_110.34768, result.data.price_per_troy_ounce, 0.00001
  end

  test "rejects an invalid quote currency without making a request" do
    provider = Provider::GoldApi.new("test-key")

    result = provider.fetch_gold_price(currency: "US/../D")

    assert_not result.success?
    assert_instance_of Provider::GoldApi::Error, result.error
  end
end
