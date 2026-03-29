# frozen_string_literal: true

require "test_helper"

class BinanceItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
    @provider = mock
    @provider.stubs(:get_spot_price).returns("50000.0")

    stub_spot_result([{ symbol: "BTC", free: "1.0", locked: "0.0", total: "1.0" }])
    stub_margin_result([])
    stub_earn_result([])
  end

  test "creates a binance_account of type combined" do
    assert_difference "@item.binance_accounts.count", 1 do
      BinanceItem::Importer.new(@item, binance_provider: @provider).import
    end

    ba = @item.binance_accounts.first
    assert_equal "combined", ba.account_type
    assert_equal "USD", ba.currency
  end

  test "calculates combined USD balance" do
    @provider.stubs(:get_spot_price).with("BTCUSDT").returns("50000.0")

    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    ba = @item.binance_accounts.first
    assert_in_delta 50000.0, ba.current_balance.to_f, 0.01
  end

  test "stablecoins counted at 1.0 without API call" do
    stub_spot_result([{ symbol: "USDT", free: "1000.0", locked: "0.0", total: "1000.0" }])

    @provider.expects(:get_spot_price).never

    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    ba = @item.binance_accounts.first
    assert_in_delta 1000.0, ba.current_balance.to_f, 0.01
  end

  test "skips BinanceAccount creation when all sources empty" do
    stub_spot_result([])
    stub_margin_result([])
    stub_earn_result([])

    assert_no_difference "@item.binance_accounts.count" do
      BinanceItem::Importer.new(@item, binance_provider: @provider).import
    end
  end

  test "stores source breakdown in raw_payload" do
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    ba = @item.binance_accounts.first
    assert ba.raw_payload.key?("spot")
    assert ba.raw_payload.key?("margin")
    assert ba.raw_payload.key?("earn")
  end

  private

    def stub_spot_result(assets)
      BinanceItem::SpotImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "spot" }
      )
    end

    def stub_margin_result(assets)
      BinanceItem::MarginImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "margin" }
      )
    end

    def stub_earn_result(assets)
      BinanceItem::EarnImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "earn" }
      )
    end
end
