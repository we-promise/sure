# frozen_string_literal: true

require "test_helper"

class BinanceItem::EarnImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
  end

  test "merges flexible and locked positions with source=earn" do
    @provider.stubs(:get_simple_earn_flexible).returns({
      "rows" => [ { "asset" => "USDT", "totalAmount" => "500.0" } ]
    })
    @provider.stubs(:get_simple_earn_locked).returns({
      "rows" => [ { "asset" => "BNB", "amount" => "10.0" } ]
    })

    result = BinanceItem::EarnImporter.new(@item, provider: @provider).import

    assert_equal "earn", result[:source]
    assert_equal 2, result[:assets].size
    usdt = result[:assets].find { |a| a[:symbol] == "USDT" }
    assert_equal "500.0", usdt[:total]
    assert_equal "500.0", usdt[:free]
    assert_equal "0.0", usdt[:locked]
    bnb = result[:assets].find { |a| a[:symbol] == "BNB" }
    assert_equal "10.0", bnb[:total]
    assert_equal "0.0", bnb[:free]
    assert_equal "10.0", bnb[:locked]
  end

  test "deduplicates assets from flexible and locked by summing" do
    @provider.stubs(:get_simple_earn_flexible).returns({
      "rows" => [ { "asset" => "BTC", "totalAmount" => "1.0" } ]
    })
    @provider.stubs(:get_simple_earn_locked).returns({
      "rows" => [ { "asset" => "BTC", "amount" => "0.5" } ]
    })

    result = BinanceItem::EarnImporter.new(@item, provider: @provider).import

    assert_equal 1, result[:assets].size
    assert_equal "1.5", result[:assets].first[:total]
  end

  test "returns empty assets when both APIs fail" do
    @provider.stubs(:get_simple_earn_flexible).raises(Provider::Binance::ApiError, "error")
    @provider.stubs(:get_simple_earn_locked).raises(Provider::Binance::ApiError, "error")

    result = BinanceItem::EarnImporter.new(@item, provider: @provider).import

    assert_equal "earn", result[:source]
    assert_equal [], result[:assets]
    assert_equal({ "flexible" => nil, "locked" => nil }, result[:raw])
  end
end
