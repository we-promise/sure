# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261113100000_fix_binance_and_coinbase_trade_entry_signs")

class FixBinanceAndCoinbaseTradeEntrySignsMigrationTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
    @security = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", offline: true)
  end

  test "flips Binance and Coinbase trades whose amount disagrees with the quantity" do
    binance_buy = trade_entry("binance", "binance_spot_BTCUSDT_1", qty: 0.1, amount: -4000)
    binance_sell = trade_entry("binance", "binance_futures_BTCUSDT_2", qty: -0.1, amount: 4100, label: "Sell")
    coinbase_buy = trade_entry("coinbase", "coinbase_txn_abc", qty: 0.01, amount: -500)
    legacy_sell = trade_entry("coinbase", "coinbase_sell_def", qty: -0.01, amount: 520, label: "Sell")

    run_migration

    assert_equal 4000, binance_buy.reload.amount
    assert_equal(-4100, binance_sell.reload.amount)
    assert_equal 500, coinbase_buy.reload.amount
    assert_equal(-520, legacy_sell.reload.amount)
  end

  test "leaves an entry that already agrees, so it can run twice" do
    buy = trade_entry("binance", "binance_spot_BTCUSDT_1", qty: 0.1, amount: 4000)

    run_migration
    run_migration

    assert_equal 4000, buy.reload.amount
  end

  test "leaves an entry the user edited" do
    buy = trade_entry("coinbase", "coinbase_txn_abc", qty: 0.01, amount: -500, user_modified: true)

    run_migration

    assert_equal(-500, buy.reload.amount)
  end

  test "leaves Coinbase income, Binance P2P and other providers' trades" do
    reward = trade_entry("coinbase", "coinbase_txn_reward", qty: 0.001, amount: -66, label: "Dividend")
    p2p = trade_entry("binance", "binance_p2p_123", qty: 0.1, amount: -4000)
    kraken = trade_entry("kraken", "kraken_trade_xyz", qty: 0.1, amount: -4000)

    run_migration

    assert_equal(-66, reward.reload.amount)
    assert_equal(-4000, p2p.reload.amount)
    assert_equal(-4000, kraken.reload.amount)
  end

  private
    def trade_entry(source, external_id, qty:, amount:, label: "Buy", user_modified: false)
      @account.entries.create!(
        date: Date.current,
        name: "Trade",
        amount: amount,
        currency: "USD",
        source: source,
        external_id: external_id,
        user_modified: user_modified,
        entryable: Trade.new(security: @security, qty: qty, price: 40_000, currency: "USD", investment_activity_label: label)
      )
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        FixBinanceAndCoinbaseTradeEntrySigns.new.up
      end
    end
end
