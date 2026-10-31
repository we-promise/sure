# frozen_string_literal: true

require "test_helper"

class BinanceItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
    @provider = mock
    @provider.stubs(:get_spot_price).returns("50000.0")

    stub_spot_result([ { symbol: "BTC", free: "1.0", locked: "0.0", total: "1.0" } ])
    stub_margin_result([])
    stub_earn_result([])
    stub_futures_result([])
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
    stub_spot_result([ { symbol: "USDT", free: "1000.0", locked: "0.0", total: "1000.0" } ])

    @provider.expects(:get_spot_price).never

    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    ba = @item.binance_accounts.first
    assert_in_delta 1000.0, ba.current_balance.to_f, 0.01
  end

  test "skips BinanceAccount creation when all sources empty" do
    stub_spot_result([])
    stub_margin_result([])
    stub_earn_result([])
    stub_futures_result([])

    assert_no_difference "@item.binance_accounts.count" do
      BinanceItem::Importer.new(@item, binance_provider: @provider).import
    end
  end

  # Each sub-importer swallows its own error and answers with an empty asset
  # list, so a total outage reached the upsert looking exactly like an emptied
  # wallet. It reported success, left the previous payload in place, and the
  # holdings processor re-imported that payload as today's holdings — so an
  # asset already sold came back on every sync.
  test "a total outage is not an empty wallet" do
    stub_failed_result("spot")
    stub_failed_result("margin")
    stub_failed_result("earn")
    stub_failed_result("futures")

    assert_raises BinanceItem::Importer::AllRequestsFailed do
      BinanceItem::Importer.new(@item, binance_provider: @provider).import
    end
  end

  # A source that failed tells us nothing about what it holds. Writing only the
  # sources that answered would hand the holdings processor a list missing every
  # margin position, and it removes what is missing — so a transient error, or a
  # key without margin permission, would delete live positions.
  test "a source that failed keeps its last known assets" do
    stub_margin_result([ { symbol: "ETH", free: "2.0", locked: "0.0", total: "2.0" } ])
    BinanceItem::Importer.new(@item, binance_provider: @provider).import
    assert_equal [ "BTC", "ETH" ], payload_symbols.sort

    stub_failed_result("margin")
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    assert_equal [ "BTC", "ETH" ], payload_symbols.sort,
                 "the unavailable source's positions were dropped"
    assert_equal "margin", payload_assets.find { |a| a["symbol"] == "ETH" }["source"]
  end

  # Carried only while the source is silent: once it answers again, what it says
  # is what stands, including an asset it no longer reports.
  test "a source that answers again overrides what was carried" do
    stub_margin_result([ { symbol: "ETH", free: "2.0", locked: "0.0", total: "2.0" } ])
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    stub_failed_result("margin")
    BinanceItem::Importer.new(@item, binance_provider: @provider).import
    assert_includes payload_symbols, "ETH"

    stub_margin_result([])
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    assert_equal [ "BTC" ], payload_symbols, "the carried asset outlived the source coming back"
  end

  # A partial failure returns normally, so it never reaches the rescue that logs
  # a failed import. Support would otherwise have no record that part of the
  # wallet went unread on a sync that reported success.
  test "a source that failed is recorded against the connection" do
    stub_failed_result("margin")

    assert_difference "DebugLogEntry.count", 1 do
      BinanceItem::Importer.new(@item, binance_provider: @provider).import
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "binance", entry.provider_key
    assert_equal [ "margin" ], entry.metadata["unavailable_sources"]
    assert_equal @family, entry.family
  end

  # One call still answering means the picture is trustworthy, even if it is
  # only part of one. Only a complete outage tells us nothing.
  test "a partial outage still records what did answer" do
    stub_failed_result("margin")
    stub_failed_result("earn")
    stub_failed_result("futures")

    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    assert_equal [ "BTC" ], @item.binance_accounts.first.raw_payload["assets"].map { |a| a["symbol"] }
  end

  # The wallet an existing account was built from can legitimately empty out,
  # and that has to be written down: the holdings processor reads this payload,
  # so leaving the old one behind kept the sold assets alive indefinitely.
  test "emptying a wallet is recorded rather than skipped" do
    BinanceItem::Importer.new(@item, binance_provider: @provider).import
    assert_equal [ "BTC" ], @item.binance_accounts.first.raw_payload["assets"].map { |a| a["symbol"] }

    stub_spot_result([])
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    ba = @item.binance_accounts.first.reload
    assert_empty ba.raw_payload["assets"], "the emptied wallet kept its old asset list"
    assert_equal 0, ba.current_balance.to_d
  end

  test "stores source breakdown in raw_payload" do
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    ba = @item.binance_accounts.first
    assert ba.raw_payload.key?("spot")
    assert ba.raw_payload.key?("margin")
    assert ba.raw_payload.key?("earn")
    assert ba.raw_payload.key?("futures")
  end

  private

    def payload_assets
      @item.binance_accounts.first.reload.raw_payload["assets"]
    end

    def payload_symbols
      payload_assets.map { |a| a["symbol"] }.uniq
    end

    def stub_failed_result(source)
      klass = { "spot" => BinanceItem::SpotImporter, "margin" => BinanceItem::MarginImporter,
                "earn" => BinanceItem::EarnImporter, "futures" => BinanceItem::FuturesImporter }.fetch(source)
      klass.any_instance.stubs(:import).returns(
        { assets: [], raw: nil, source: source, error: "boom" }
      )
    end

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

    def stub_futures_result(assets)
      BinanceItem::FuturesImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "futures" }
      )
    end
end
