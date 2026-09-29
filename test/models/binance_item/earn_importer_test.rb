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

  # Both sub-requests rescue to nil, so a double failure used to be reported as
  # a successful import of no positions — and the caller decides from these
  # results whether the whole wallet is empty.
  test "returns empty assets when both APIs fail, and says they failed" do
    @provider.stubs(:get_simple_earn_flexible).raises(Provider::Binance::ApiError, "flexible down")
    @provider.stubs(:get_simple_earn_locked).raises(Provider::Binance::ApiError, "locked down")

    result = BinanceItem::EarnImporter.new(@item, provider: @provider).import

    assert_equal "earn", result[:source]
    assert_equal [], result[:assets]
    assert_equal({ "flexible" => nil, "locked" => nil }, result[:raw])
    assert_includes result[:error].to_s, "flexible down"
    assert_includes result[:error].to_s, "locked down"
  end

  # One side answering is still an answer: an account with only flexible
  # positions must not be reported as a failure.
  test "one side failing is not a failure" do
    @provider.stubs(:get_simple_earn_flexible).returns(
      { "rows" => [ { "asset" => "BTC", "totalAmount" => "1.0" } ] }
    )
    @provider.stubs(:get_simple_earn_locked).raises(Provider::Binance::ApiError, "locked down")

    result = BinanceItem::EarnImporter.new(@item, provider: @provider).import

    assert_nil result[:error]
    assert_equal [ "BTC" ], result[:assets].map { |a| a[:symbol] }
  end

  # ...but it must not cost the silent side its positions. The caller carries a
  # whole source that failed; a half-answering source slips through that, so a
  # locked position would have vanished because the flexible call happened to
  # be the one that worked.
  test "the side that went silent keeps what it last reported" do
    seed_previous_earn(symbol: "ETH", free: "1.0", locked: "3.0")

    @provider.stubs(:get_simple_earn_flexible).returns(
      { "rows" => [ { "asset" => "ETH", "totalAmount" => "2.0" } ] }
    )
    @provider.stubs(:get_simple_earn_locked).raises(Provider::Binance::ApiError, "locked down")

    asset = BinanceItem::EarnImporter.new(@item, provider: @provider).import[:assets].first

    assert_equal "2.0", asset[:free], "the side that answered was not taken fresh"
    assert_equal "3.0", asset[:locked], "the silent side lost its position"
    assert_equal "5.0", asset[:total]
  end

  # The reverse direction, and the case where the silent side is the only one
  # holding the asset at all.
  test "an asset held only on the silent side survives" do
    seed_previous_earn(symbol: "SOL", free: "4.0", locked: "0.0")

    @provider.stubs(:get_simple_earn_flexible).raises(Provider::Binance::ApiError, "flexible down")
    @provider.stubs(:get_simple_earn_locked).returns({ "rows" => [] })

    assets = BinanceItem::EarnImporter.new(@item, provider: @provider).import[:assets]

    assert_equal [ "SOL" ], assets.map { |a| a[:symbol] }
    assert_equal "4.0", assets.first[:total]
  end

  # One side down does not fail the import, so the caller never records it. The
  # endpoint that stopped answering would otherwise be invisible in
  # /settings/debug, while positions are quietly carried because of it.
  test "a side that went silent is recorded against the connection" do
    @provider.stubs(:get_simple_earn_flexible).returns({ "rows" => [] })
    @provider.stubs(:get_simple_earn_locked).raises(Provider::Binance::ApiError, "locked down")

    assert_difference "DebugLogEntry.count", 1 do
      BinanceItem::EarnImporter.new(@item, provider: @provider).import
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "binance", entry.provider_key
    assert_equal [ "locked" ], entry.metadata["unavailable_endpoints"]
    assert_equal "locked down", entry.metadata.dig("errors", "locked")
  end

  test "both sides answering records nothing" do
    @provider.stubs(:get_simple_earn_flexible).returns({ "rows" => [] })
    @provider.stubs(:get_simple_earn_locked).returns({ "rows" => [] })

    assert_no_difference "DebugLogEntry.count" do
      BinanceItem::EarnImporter.new(@item, provider: @provider).import
    end
  end

  private
    def seed_previous_earn(symbol:, free:, locked:)
      @item.binance_accounts.create!(
        name: "Binance", account_type: "combined", currency: "USD", current_balance: 0,
        raw_payload: { "assets" => [
          { "symbol" => symbol, "free" => free, "locked" => locked,
            "total" => (free.to_d + locked.to_d).to_s("F"), "source" => "earn" }
        ] }
      )
    end
end
