require "test_helper"

class BinanceItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @binance_item = BinanceItem.create!(
      family: @family,
      name: "Test Binance",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "imports spot holdings and trade snapshots" do
    provider = mock("binance_provider")
    provider.stubs(:get_account).returns(
      "uid" => 12345,
      "accountType" => "SPOT",
      "canTrade" => true,
      "permissions" => [ "SPOT" ],
      "balances" => [
        { "asset" => "BTC", "free" => "1.0", "locked" => "0" },
        { "asset" => "USDT", "free" => "1000", "locked" => "0" }
      ]
    )
    provider.stubs(:get_all_coin_info).returns(
      [
        { "coin" => "BTC", "name" => "Bitcoin" },
        { "coin" => "USDT", "name" => "Tether USD" }
      ]
    )
    provider.stubs(:get_exchange_info).returns(
      "symbols" => [
        { "symbol" => "BTCUSDT", "status" => "TRADING", "baseAsset" => "BTC", "quoteAsset" => "USDT" }
      ]
    )
    provider.stubs(:get_all_prices).returns({ "BTCUSDT" => BigDecimal("50000") })
    provider.stubs(:get_deposit_history).returns([])
    provider.stubs(:get_withdraw_history).returns([])
    provider.stubs(:get_my_trades).with(symbol: "BTCUSDT", from_id: nil, limit: 1000).returns(
      [
        {
          "id" => 1,
          "price" => "50000",
          "qty" => "0.1",
          "quoteQty" => "5000",
          "commission" => "5",
          "commissionAsset" => "USDT",
          "time" => Time.utc(2026, 1, 5).to_i * 1000,
          "isBuyer" => true
        }
      ]
    )

    result = BinanceItem::Importer.new(@binance_item, binance_provider: provider).import

    assert_equal true, result[:success]
    assert_equal 1, @binance_item.binance_accounts.count

    provider_account = @binance_item.binance_accounts.first
    assert_equal "Binance Spot", provider_account.name
    assert_equal "USD", provider_account.currency
    assert_equal BigDecimal("51000"), provider_account.current_balance
    assert_equal 2, provider_account.raw_holdings_payload.size
    assert_equal 1, provider_account.raw_transactions_payload["trades"].size
    assert_equal "5000.0", provider_account.raw_transactions_payload["trades"].first["valuation_amount"]
  end
end
