require "test_helper"
require_relative "../../support/account_sync_input_test_helper"

class Account::SyncerNativeHistoryTest < ActiveSupport::TestCase
  include AccountSyncInputTestHelper
  self.use_transactional_tests = false

  test "repairs the default anchor before actual materialization and applies exact equity afterwards preserving IDs" do
    with_account_input do
      seed_account_history
      assert_equal BigDecimal("3351"), @account.opening_anchor_balance
      original_ids = @account.entries.order(:id).pluck(:id, :entryable_id)
      existing = @account.balances.create!(date: Date.new(2026, 5, 8), currency: "CHF", balance: "10", cash_balance: "10")
      original_created_at = existing.created_at
      sync = enqueue_account_handoff
      sync.start!
      Account::MarketDataImporter.any_instance.expects(:import_all).with do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        true
      end
      ExchangeRate.expects(:provider).never
      IbkrAccount::HistoricalBalancesSync.any_instance.expects(:sync!).never
      Account::Syncer.new(@account).perform_sync(sync)
      assert_equal BigDecimal("0"), @opening.reload.amount
      assert_equal BigDecimal("0"), @account.balances.find_by!(date: Date.new(2026, 5, 1), currency: "CHF").end_balance
      assert_equal BigDecimal("3351"), existing.reload.end_balance
      assert_equal original_created_at, existing.created_at
      assert_equal original_ids, @account.entries.order(:id).pluck(:id, :entryable_id)
      assert sync.reload.account_materialized_at
      assert_equal %w[opening_anchor_repairs historical_balances].sort,
        @connection.ingestion_batches.applied.where(stream: %w[opening_anchor_repairs historical_balances]).pluck(:stream).sort
      assert_provider_column_encrypted(sync.account_sync_preparation, :payload, "inputs_sha256")
      assert_raises(ActiveRecord::StatementInvalid) do
        Account::SyncPreparation.transaction(requires_new: true) { Account::SyncPreparation.where(sync: sync).delete_all }
      end
      state = @account.balances.order(:id).map(&:attributes)
      Account::MarketDataImporter.any_instance.expects(:import_all).never
      assert_no_difference "IngestionBatch.count" { Account::Syncer.new(@account).perform_sync(sync) }
      assert_equal state, @account.balances.order(:id).map(&:attributes)
    end
  end

  test "missing materialization FX rolls back anchor holdings balances and completion together" do
    with_account_input do
      seed_account_history
      @account.entries.create!(name: "Foreign cash", date: Date.new(2026, 5, 5), amount: "20", currency: "EUR", entryable: Transaction.new)
      ExchangeRate.where(from_currency: "EUR", to_currency: "CHF").delete_all
      sync = enqueue_account_handoff
      sync.start!
      Account::MarketDataImporter.any_instance.stubs(:import_all)
      ExchangeRate.expects(:provider).never
      before = @account.entries.order(:id).map(&:attributes)
      assert_no_difference [ "Balance.count", "Holding.count", "IngestionBatch.count" ] do
        assert_raises(ExchangeRate::Provided::MissingCachedRate) { Account::Syncer.new(@account).perform_sync(sync) }
      end
      assert_equal before, @account.entries.order(:id).map(&:attributes)
      assert_equal BigDecimal("3351"), @opening.reload.amount
      assert_nil sync.reload.account_materialized_at
      assert sync.account_sync_preparation
      ExchangeRate.create!(from_currency: "EUR", to_currency: "CHF", date: Date.new(2026, 5, 5), rate: "0.9")
      Account::Syncer.new(@account).perform_sync(sync)
      assert sync.reload.account_materialized_at
    end
  end

  test "preparation pins all-account trade FX and rejects edits before publication" do
    with_account_input do
      seed_account_history
      entry = @account.entries.create!(name: "Manual trade", date: Date.new(2026, 5, 7), amount: "10", currency: "CHF",
        user_modified: true, entryable: Trade.new(qty: 1, price: 10, currency: "CHF", security: securities(:aapl)))
      sync = enqueue_account_handoff
      sync.start!
      snapshot = Ingestion::HistoricalBalances::TradeFlowSnapshot.capture(account: @account)
      sync.create_account_sync_preparation!(input_digest: sync.account_inputs_digest, payload: snapshot.payload)
      entry.update!(amount: "20")
      Account::MarketDataImporter.any_instance.stubs(:import_all)
      assert_no_difference [ "Balance.count", "Holding.count", "IngestionBatch.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) { Account::Syncer.new(@account).perform_sync(sync) }
      end
      assert_equal BigDecimal("3351"), @opening.reload.amount
    end
  end

  test "revoked handoff rejects before market data or normal materialization" do
    with_account_input do
      seed_account_history
      sync = enqueue_account_handoff
      sync.start!
      @link.touch
      Account::MarketDataImporter.any_instance.expects(:import_all).never
      Balance::Materializer.any_instance.expects(:materialize_balances).never
      assert_raises(Provider::AccountData::StaleWriter) { Account::Syncer.new(@account).perform_sync(sync) }
      assert_nil sync.reload.account_materialized_at
    end
  end

  test "a native historical owner without an explicit input cannot fall back to compatibility data" do
    with_account_input do
      sync = @account.sync_later
      sync.start!
      Account::MarketDataImporter.any_instance.expects(:import_all).never
      IbkrAccount::HistoricalBalancesSync.any_instance.expects(:sync!).never
      assert_raises(Provider::AccountData::IncompletePage) { Account::Syncer.new(@account).perform_sync(sync) }
      assert_nil sync.reload.account_materialized_at
    end
  end

  test "reconciled opening anchors retain their values through native preparation" do
    with_account_input do
      seed_account_history
      @opening.update!(reconciled_at: Time.current)
      sync = enqueue_account_handoff
      sync.start!
      Account::MarketDataImporter.any_instance.stubs(:import_all)
      Account::Syncer.new(@account).perform_sync(sync)
      assert_equal BigDecimal("3351"), @opening.reload.amount
      command = @connection.ingestion_batches.find_by!(stream: "opening_anchor_repairs")
      assert_nil Ingestion::HistoricalBalances::Command.load(command.payload)[:opening_anchor]
    end
  end

  test "Sync perform completes a native child and duplicate jobs do not run it again" do
    with_account_input do
      seed_account_history
      sync = enqueue_account_handoff
      Account::MarketDataImporter.any_instance.expects(:import_all).once
      Account.any_instance.expects(:perform_post_sync).once
      Account.any_instance.stubs(:broadcast_sync_complete)
      sync.perform
      assert sync.reload.completed?, sync.error
      assert sync.account_materialized_at
      balances = @account.balances.order(:id).map(&:attributes)
      sync.perform
      assert_equal balances, @account.balances.order(:id).map(&:attributes)
    end
  end

  test "a crash after financial commit finalizes the same source without a second materialization" do
    with_account_input do
      seed_account_history
      sync = enqueue_account_handoff
      sync.start!
      Account::MarketDataImporter.any_instance.expects(:import_all).once
      Account::Syncer.new(@account).perform_sync(sync)
      marker = sync.reload.account_materialized_at
      Balance::Materializer.any_instance.expects(:materialize_balances).never
      Account.any_instance.expects(:perform_post_sync).once
      Account.any_instance.stubs(:broadcast_sync_complete)
      sync.perform
      assert sync.reload.completed?, sync.error
      assert_equal marker, sync.account_materialized_at
      assert_equal @handoff.payload, sync.account_sync_inputs.sole.payload
    end
  end
end
