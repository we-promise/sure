# frozen_string_literal: true

require "test_helper"

class BinanceItem::MarginImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
  end

  test "returns normalized assets from userAssets with source=margin" do
    @provider.stubs(:get_margin_account).returns({
      "userAssets" => [
        { "asset" => "BTC", "free" => "0.1", "locked" => "0.0", "netAsset" => "0.1" },
        { "asset" => "ETH", "free" => "0.0", "locked" => "0.0", "netAsset" => "0.0" }
      ]
    })

    result = BinanceItem::MarginImporter.new(@item, provider: @provider).import

    assert_equal "margin", result[:source]
    assert_equal 1, result[:assets].size
    btc = result[:assets].first
    assert_equal "BTC", btc[:symbol]
    assert_equal "0.1", btc[:total]
  end

  test "returns empty on API error" do
    @provider.stubs(:get_margin_account).raises(Provider::Binance::ApiError, "WAF")

    result = BinanceItem::MarginImporter.new(@item, provider: @provider).import

    assert_equal "margin", result[:source]
    assert_equal [], result[:assets]
  end
end
