# frozen_string_literal: true

require "test_helper"

class CoinspotItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = CoinspotItem.create!(
      family: @family,
      name: "CoinSpot",
      api_key: "k",
      api_secret: "s"
    )
    @provider = mock
    @provider.stubs(:status).returns({ "status" => "ok" })
    @provider.stubs(:get_order_history).returns({ "buyorders" => [], "sellorders" => [] })
    @provider.stubs(:get_send_receive_history).returns({ "sendtransactions" => [], "receivetransactions" => [] })
    @provider.stubs(:get_deposit_history).returns({ "deposits" => [] })
    @provider.stubs(:get_withdrawal_history).returns({ "withdrawals" => [] })
  end

  test "creates a combined coinspot account from balances" do
    @provider.stubs(:get_balances).returns(
      "status" => "ok",
      "balances" => [
        { "btc" => { "balance" => "0.5", "audbalance" => "50000.00", "rate" => "100000.00" } },
        { "aud" => { "balance" => "125.50", "audbalance" => "125.50", "rate" => "1.00" } },
        { "eth" => { "balance" => "0", "audbalance" => "0", "rate" => "5000.00" } }
      ]
    )

    assert_difference "@item.coinspot_accounts.count", 1 do
      result = CoinspotItem::Importer.new(@item, coinspot_provider: @provider).import
      assert_equal 2, result[:assets_imported]
      assert_in_delta 50_125.50, result[:total_aud], 0.01
    end

    account = @item.coinspot_accounts.first
    assert_equal "combined", account.account_id
    assert_equal "combined", account.account_type
    assert_equal "AUD", account.currency
    assert_in_delta 50_125.50, account.current_balance, 0.01

    btc = account.raw_payload["assets"].find { |asset| asset["symbol"] == "BTC" }
    assert_equal "0.5", btc["balance"]
    assert_equal "50000.0", btc["amount_aud"]
    assert_equal "100000.0", btc["price_aud"]
  end

  test "falls back to market order history when standard order history is unavailable" do
    @provider.stubs(:get_balances).returns("balances" => [])
    @provider.stubs(:get_order_history).raises(Provider::Coinspot::ApiError, "unavailable")
    @provider.expects(:get_market_order_history).returns({ "orders" => [ { "coin" => "BTC" } ] })

    result = CoinspotItem::Importer.new(@item, coinspot_provider: @provider).import

    assert_equal 1, result[:orders_imported]
    assert_equal [ { "coin" => "BTC" } ], @item.coinspot_accounts.first.raw_transactions_payload.dig("orders", "orders")
  end

  test "marks item requires update when permissions are invalid" do
    @provider.stubs(:get_balances).raises(Provider::Coinspot::PermissionError, "Permission denied")

    assert_raises(Provider::Coinspot::PermissionError) do
      CoinspotItem::Importer.new(@item, coinspot_provider: @provider).import
    end

    assert @item.reload.requires_update?
  end
end
