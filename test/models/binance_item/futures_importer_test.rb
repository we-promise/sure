# frozen_string_literal: true

require "test_helper"

class BinanceItem::FuturesImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
  end

  test "returns normalized assets from USDⓈ-M futures with source=futures" do
    @provider.stubs(:get_futures_account).returns({
      "assets" => [
        { "asset" => "USDT", "walletBalance" => "100.0", "unrealizedProfit" => "5.0", "availableBalance" => "90.0" },
        { "asset" => "BUSD", "walletBalance" => "0.0", "unrealizedProfit" => "0.0", "availableBalance" => "0.0" }
      ],
      "positions" => [
        { "symbol" => "BTCUSDT", "positionAmt" => "0.5" }
      ]
    })

    result = BinanceItem::FuturesImporter.new(@item, provider: @provider).import

    assert_equal "futures", result[:source]
    assert_equal 1, result[:assets].size
    usdt = result[:assets].first
    assert_equal "USDT", usdt[:symbol]
    assert_equal "105.0", usdt[:total] # walletBalance + unrealizedProfit
    assert_equal "90.0", usdt[:free]
    assert_equal "10.0", usdt[:locked] # walletBalance - availableBalance
  end

  test "returns empty on API error" do
    @provider.stubs(:get_futures_account).raises(Provider::Binance::ApiError, "WAF")

    result = BinanceItem::FuturesImporter.new(@item, provider: @provider).import

    assert_equal "futures", result[:source]
    assert_equal [], result[:assets]
  end
end
