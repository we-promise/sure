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
    @provider.stubs(:get_market_order_history).returns({ "orders" => [ { "id" => "m1", "coin" => "BTC" } ] })

    result = CoinspotItem::Importer.new(@item, coinspot_provider: @provider).import

    assert_equal 1, result[:orders_imported]
    payload = @item.coinspot_accounts.first.raw_transactions_payload
    assert_equal [ { "id" => "m1", "coin" => "BTC" } ], payload.dig("orders", "orders")
    assert_equal [], payload.dig("orders", "buyorders")
  end

  test "does not raise when both order history endpoints fail for the same window" do
    @provider.stubs(:get_balances).returns("balances" => [])
    @provider.stubs(:get_order_history).raises(Provider::Coinspot::ApiError, "unavailable")
    @provider.stubs(:get_market_order_history).raises(Provider::Coinspot::ApiError, "also unavailable")

    result = CoinspotItem::Importer.new(@item, coinspot_provider: @provider).import

    assert_equal 0, result[:orders_imported]
    payload = @item.coinspot_accounts.first.raw_transactions_payload
    assert_equal [], payload.dig("orders", "buyorders")
    assert_equal [], payload.dig("orders", "sellorders")
    assert_equal [], payload.dig("orders", "orders")
  end

  test "preserves sell orders alongside buy orders from the primary endpoint" do
    @provider.stubs(:get_balances).returns("balances" => [])
    @provider.stubs(:get_order_history).returns(
      "buyorders" => [ { "id" => "b1", "coin" => "BTC" } ],
      "sellorders" => [ { "id" => "s1", "coin" => "BTC" } ]
    )

    result = CoinspotItem::Importer.new(@item, coinspot_provider: @provider).import

    assert_equal 2, result[:orders_imported]
    payload = @item.coinspot_accounts.first.raw_transactions_payload
    assert_equal [ { "id" => "b1", "coin" => "BTC" } ], payload.dig("orders", "buyorders")
    assert_equal [ { "id" => "s1", "coin" => "BTC" } ], payload.dig("orders", "sellorders")
  end

  test "bisects a window that comes back saturated at the record limit" do
    travel_to Date.new(2026, 1, 20) do
      @provider.stubs(:get_balances).returns("balances" => [])
      @item.update!(sync_start_date: Date.new(2026, 1, 1))

      full_window_orders = Array.new(CoinspotItem::Importer::ORDER_HISTORY_LIMIT) { |i| { "id" => "sat-#{i}", "coin" => "BTC" } }
      first_half_orders = [ { "id" => "half-1", "coin" => "BTC" } ]
      second_half_orders = [ { "id" => "half-2", "coin" => "BTC" } ]

      @provider.stubs(:get_order_history).with(startdate: Date.new(2026, 1, 1), enddate: Date.new(2026, 1, 20))
        .returns("buyorders" => full_window_orders, "sellorders" => [])
      @provider.stubs(:get_order_history).with(startdate: Date.new(2026, 1, 1), enddate: Date.new(2026, 1, 10))
        .returns("buyorders" => first_half_orders, "sellorders" => [])
      @provider.stubs(:get_order_history).with(startdate: Date.new(2026, 1, 11), enddate: Date.new(2026, 1, 20))
        .returns("buyorders" => second_half_orders, "sellorders" => [])

      CoinspotItem::Importer.new(@item, coinspot_provider: @provider).import

      buyorders = @item.coinspot_accounts.first.raw_transactions_payload.dig("orders", "buyorders")
      assert_equal %w[half-1 half-2], buyorders.map { |order| order["id"] }.sort
    end
  end

  test "marks item requires update when permissions are invalid" do
    @provider.stubs(:get_balances).raises(Provider::Coinspot::PermissionError, "Permission denied")

    assert_raises(Provider::Coinspot::PermissionError) do
      CoinspotItem::Importer.new(@item, coinspot_provider: @provider).import
    end

    assert @item.reload.requires_update?
  end
end
