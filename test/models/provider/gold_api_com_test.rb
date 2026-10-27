require "test_helper"

class Provider::GoldApiComTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::GoldApiCom.new
  end

  test "returns the USD spot price per troy ounce dated by its update time" do
    stub_response("/price/XAG", { "name" => "Silver", "price" => 38.25, "symbol" => "XAG", "updatedAt" => "2026-09-03T12:00:00Z" })

    result = @provider.fetch_bullion_price(symbol: "XAG")

    assert result.success?
    assert_equal "USD", result.data.currency
    assert_equal "XAG", result.data.symbol
    assert_equal Date.new(2026, 9, 3), result.data.date
    assert_in_delta 38.25, result.data.price_per_troy_ounce, 0.00001
  end

  test "rejects an unsupported symbol without making a request" do
    @provider.expects(:client).never

    result = @provider.fetch_bullion_price(symbol: "../XAU")

    assert_not result.success?
    assert_instance_of Provider::GoldApiCom::Error, result.error
  end

  test "rejects a zero price" do
    stub_response("/price/XAU", { "price" => 0, "updatedAt" => "2026-09-03T12:00:00Z" })

    assert_not @provider.fetch_bullion_price(symbol: "XAU").success?
  end

  test "rejects a quote without a timestamp" do
    stub_response("/price/XAU", { "price" => 3_110.34768 })

    assert_not @provider.fetch_bullion_price(symbol: "XAU").success?
  end

  test "client raises on HTTP error responses" do
    assert_includes @provider.send(:client).builder.handlers, Faraday::Response::RaiseError
  end

  test "is available from the registry without an API key" do
    assert_instance_of Provider::GoldApiCom, Provider::Registry.get_provider(:gold_api_com)
  end

  private
    def stub_response(path, body)
      client = mock
      client.expects(:get).with(path).returns(Struct.new(:body).new(body.to_json))
      @provider.stubs(:client).returns(client)
    end
end
