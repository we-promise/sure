# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260927142423_fix_kraken_trade_entry_signs")

class FixKrakenTradeEntrySignsMigrationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:investment)
    @security = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", offline: true)
  end

  test "flips an entry whose amount disagrees with its trade's quantity" do
    buy  = kraken_trade("buy_tx",  qty: 0.001,  amount: -50)   # a buy written as money in
    sell = kraken_trade("sell_tx", qty: -0.002, amount: 120)   # a sell written as money out

    # The balance series was derived from the wrong flows and has to be rebuilt.
    assert_difference -> { @account.syncs.count }, 1 do
      assert_enqueued_with(job: SyncJob) { run_migration }
    end

    assert_equal 50, buy.reload.amount
    assert_equal(-120, sell.reload.amount)
  end

  # A sync already running may have materialized the old flows moments before
  # the flip. `sync_later` would reuse it and queue nothing, so the rebuild is
  # a distinct sync, run once that one can no longer be reused.
  test "queues a fresh rebuild even when a sync is already in flight" do
    kraken_trade("buy_tx", qty: 0.001, amount: -50)
    in_flight = @account.syncs.create!
    in_flight.start!

    freeze_time do
      assert_difference -> { @account.syncs.count }, 1 do
        run_migration
      end

      assert_enqueued_with(job: SyncJob, at: Sync::VISIBLE_FOR.from_now)
    end
  end

  test "leaves an entry that already agrees, so it can run twice" do
    buy = kraken_trade("buy_tx", qty: 0.001, amount: 50)

    assert_no_difference -> { @account.syncs.count } do
      run_migration
      run_migration
    end

    assert_equal 50, buy.reload.amount
  end

  test "leaves an entry the user edited" do
    buy = kraken_trade("buy_tx", qty: 0.001, amount: -50, user_modified: true)

    run_migration

    assert_equal(-50, buy.reload.amount)
  end

  test "leaves entries from other sources and other Kraken entry kinds" do
    other  = kraken_trade("buy_tx", qty: 0.001, amount: -50, source: "binance", external_id: "binance_trade_buy_tx")
    ledger = kraken_trade("dep", qty: 0.001, amount: -50, external_id: "kraken_ledger_dep")

    run_migration

    assert_equal(-50, other.reload.amount)
    assert_equal(-50, ledger.reload.amount)
  end

  private
    def kraken_trade(txid, qty:, amount:, user_modified: false, source: "kraken", external_id: nil)
      @account.entries.create!(
        date: Date.current,
        name: "Trade",
        amount: amount,
        currency: "USD",
        source: source,
        external_id: external_id || "kraken_trade_#{txid}",
        user_modified: user_modified,
        entryable: Trade.new(security: @security, qty: qty, price: 50_000, currency: "USD")
      )
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        FixKrakenTradeEntrySigns.new.up
      end
    end
end
