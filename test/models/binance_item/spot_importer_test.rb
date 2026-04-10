# frozen_string_literal: true

require "test_helper"

class BinanceItem::SpotImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
  end

  test "returns normalized assets with source=spot" do
    @provider.stubs(:get_spot_account).returns({
      "balances" => [
        { "asset" => "BTC", "free" => "1.5", "locked" => "0.5" },
        { "asset" => "ETH", "free" => "10.0", "locked" => "0.0" },
        { "asset" => "SHIB", "free" => "0.0", "locked" => "0.0" }
      ]
    })

    result = BinanceItem::SpotImporter.new(@item, provider: @provider).import

    assert_equal "spot", result[:source]
    assert_equal 2, result[:assets].size  # SHIB filtered out (zero balance)
    btc = result[:assets].find { |a| a[:symbol] == "BTC" }
    assert_equal "1.5", btc[:free]
    assert_equal "0.5", btc[:locked]
    assert_equal "2.0", btc[:total]
  end

  test "returns empty assets on API error" do
    @provider.stubs(:get_spot_account).raises(Provider::Binance::AuthenticationError, "Invalid key")

    result = BinanceItem::SpotImporter.new(@item, provider: @provider).import

    assert_equal "spot", result[:source]
    assert_equal [], result[:assets]
    assert_nil result[:raw]
  end

  test "filters out zero-balance assets" do
    @provider.stubs(:get_spot_account).returns({
      "balances" => [
        { "asset" => "BTC", "free" => "0.0", "locked" => "0.0" },
        { "asset" => "ETH", "free" => "0.0", "locked" => "0.0" }
      ]
    })

    result = BinanceItem::SpotImporter.new(@item, provider: @provider).import

    assert_equal [], result[:assets]
  end
end
