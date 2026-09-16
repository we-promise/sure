require "test_helper"
require "ostruct"
require_relative "../../support/account_sync_input_test_helper"

class Account::SyncerOwnerAdmissionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    Family.any_instance.stubs(:broadcast_refresh)
    DebugLogEntry.stubs(:capture)
  end

  test "a stale receiver whose owner is already pending deletion cannot start market data" do
    with_financial_account do |account|
      worker = Account::Syncer.new(account)
      Account.where(id: account.id).update_all(status: "pending_deletion")
      Account::MarketDataImporter.expects(:new).never
      Balance::Materializer.expects(:new).never

      assert_raises(Account::SyncAdmission::Unavailable) { worker.perform_sync(calculation) }
      assert account.active?, "the original receiver remains stale"
    end
  end

  test "pending missing and retired owners after market data cannot publish balances holdings or preparation" do
    %i[pending missing retired].each do |change|
      with_financial_account do |account|
        identity = Account::IngestionIdentity.capture!(account: account) if change == :retired
        worker = Account::Syncer.new(account)
        transactions = market_data(account) do
          if change == :pending
            Account.where(id: account.id).update_all(status: "pending_deletion")
          elsif change == :missing
            Account.where(id: account.id).delete_all
          else
            # Test-only database retirement of an otherwise unused identity.
            # This exercises the actual deferred constraint, not a public erase API.
            ApplicationRecord.transaction do
              Account::IngestionIdentity.where(id: identity.id).update_all(live_account_id: nil, retired_at: Time.current)
              Account.where(id: account.id).delete_all
              ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement IMMEDIATE")
            end
          end
        end
        Balance::Materializer.expects(:new).never

        assert_no_difference [ "Balance.count", "Holding.count", "Entry.count", "Account::SyncPreparation.count" ] do
          assert_raises(Account::SyncAdmission::Unavailable, change.to_s) { worker.perform_sync(calculation) }
        end
        assert_equal [ 0 ], transactions, "market data must run outside publication transactions"
        assert identity.reload.retired? if identity
      end
    end
  end

  test "ordinary balance calculation still publishes from the admitted fresh account" do
    with_financial_account do |account|
      account.entries.create!(name: "Opening balance", date: Date.current - 1, amount: 42, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor"))
      transactions = market_data(account)
      ExchangeRate.expects(:provider).never

      Account::Syncer.new(account).perform_sync(calculation)

      assert_equal [ 0 ], transactions
      assert_equal BigDecimal("42"), account.reload.balance
      assert_equal BigDecimal("42"), account.balances.order(:date).last.end_balance
    end
  end

  test "ordinary publication uses cached foreign transaction rates without HTTP" do
    rate = ExchangeRate.create!(from_currency: "BHD", to_currency: "USD", date: Date.current, rate: 2)
    with_financial_account do |account|
      account.entries.create!(name: "Opening balance", date: Date.current - 1, amount: 42, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor"))
      foreign = account.entries.create!(name: "Foreign transaction", date: Date.current, amount: 3, currency: "BHD",
        entryable: Transaction.new)
      transactions = market_data(account)
      ExchangeRate.expects(:provider).never

      Account::Syncer.new(account).perform_sync(calculation)

      assert_equal [ 0 ], transactions
      assert_equal BigDecimal("36"), account.reload.balance
      assert_equal BigDecimal("6"), account.balances.find_by!(date: Date.current, currency: "USD").cash_outflows
      assert_equal BigDecimal("3"), foreign.reload.amount
      assert_equal "BHD", foreign.currency
    end
  ensure
    rate&.destroy!
  end

  test "missing publication FX rolls back ordinary balances without fetching while locked" do
    with_financial_account do |account|
      account.entries.create!(name: "Foreign transaction", date: Date.current - 1, amount: 3, currency: "BHD",
        entryable: Transaction.new)
      assert_empty ExchangeRate.where(from_currency: "BHD", to_currency: "USD")
      holding = account.holdings.create!(security: securities(:aapl), date: Date.current, currency: "USD", qty: 1, price: 10, amount: 10)
      original_holding = holding.attributes
      original = account.reload.attributes
      transactions = market_data(account)
      ExchangeRate.expects(:provider).never

      assert_no_difference [ "Balance.count", "Holding.count", "Account::SyncPreparation.count" ] do
        assert_raises(ExchangeRate::Provided::MissingCachedRate) { Account::Syncer.new(account).perform_sync(calculation) }
      end

      assert_equal [ 0 ], transactions
      assert_equal original, account.reload.attributes
      assert_equal original_holding, holding.reload.attributes, "the early stale-holding purge must roll back with missing FX"
    end
  end

  test "a real ordinary sync cancelled or finalized during market data cannot publish" do
    [ { cancel_requested_at: Time.current }, { status: "failed" } ].each do |change|
      with_financial_account do |account|
        sync = account.sync_later
        sync.start!
        original_seal = sync.attributes.slice("account_inputs_sealed_at", "account_inputs_digest")
        transactions = market_data(account) { Sync.where(id: sync.id).update_all(change) }
        Balance::Materializer.expects(:new).never

        assert_no_difference [ "Balance.count", "Holding.count", "Account::SyncPreparation.count" ] do
          assert_raises(Provider::AccountData::StaleWriter) { Account::Syncer.new(account).perform_sync(sync) }
        end

        assert_equal [ 0 ], transactions
        assert_equal original_seal, sync.reload.attributes.slice(*original_seal.keys)
      end
    end
  end

  test "legacy IBKR overrides retain their totals through real fence and fresh account admission" do
    with_financial_account do |account|
      source = legacy_ibkr_source(account)
      source.update!(raw_equity_summary_payload: [ { "report_date" => Date.current.iso8601, "total" => "250" } ])
      transactions = market_data(account)
      ExchangeRate.expects(:provider).never

      Account::Syncer.new(account).perform_sync(calculation)

      assert_equal [ 0 ], transactions
      assert_equal BigDecimal("250"), account.balances.find_by!(date: Date.current, currency: "USD").end_balance
    end
  end

  test "legacy override does not swallow an owner denial after ordinary materialization" do
    with_financial_account do |account|
      legacy_ibkr_source(account)
      market_data(account)
      materializer = Object.new
      materializer.define_singleton_method(:materialize_balances) do
        Account.where(id: account.id).update_all(status: "pending_deletion")
      end
      Balance::Materializer.expects(:new).returns(materializer)
      IbkrAccount::HistoricalBalancesSync.expects(:new).never

      assert_raises(Account::SyncAdmission::Unavailable) { Account::Syncer.new(account).perform_sync(calculation) }
      assert account.reload.pending_deletion?
    end
  end

  test "legacy override missing FX propagates without fetching or replacing existing balances" do
    with_financial_account do |account|
      source = legacy_ibkr_source(account)
      source.update!(raw_equity_summary_payload: [ { "report_date" => Date.current.iso8601, "total" => "250" } ])
      account.entries.create!(name: "Foreign trade", date: Date.current, amount: 3, currency: "BHD",
        entryable: Trade.new(qty: 1, price: 3, currency: "BHD", security: securities(:aapl)))
      balance = account.balances.create!(date: Date.current, currency: "USD", balance: 100, cash_balance: 100)
      original = balance.attributes
      market_data(account)
      # Isolate the second publication boundary; the ordinary calculation has
      # its own real missing-FX rollback regression above.
      Balance::Materializer.any_instance.stubs(:materialize_balances)
      ExchangeRate.expects(:provider).never

      assert_raises(ExchangeRate::Provided::MissingCachedRate) { Account::Syncer.new(account).perform_sync(calculation) }

      assert_equal original, balance.reload.attributes
      assert_equal 1, account.balances.count
    end
  end

  private
    def calculation = OpenStruct.new(window_start_date: nil)

    def market_data(account, &change)
      transactions = []
      importer = Object.new
      importer.define_singleton_method(:import_all) do
        transactions << ApplicationRecord.connection.open_transactions
        change&.call
      end
      Account::MarketDataImporter.expects(:new).with { |fresh| fresh.id == account.id && fresh.family_id == account.family_id }.returns(importer)
      transactions
    end

    def legacy_ibkr_source(account)
      item = account.family.ibkr_items.create!(name: "Legacy balance owner", query_id: "QUERY", token: "test-token")
      source = item.ibkr_accounts.create!(name: "Brokerage", ibkr_account_id: "U123", currency: "USD")
      AccountProvider.create!(account: account, provider: source)
      source
    end

    def with_financial_account
      with_provider_encryption do
        family = Family.create!(name: "Account publication admission")
        account = family.accounts.create!(name: "Financial owner", currency: "USD", balance: 100, cash_balance: 100,
          accountable: Investment.new, status: "active")
        accountable = account.accountable
        begin
          yield account
        ensure
          Account.find_by(id: account.id)&.destroy!
          # Raw deletion in the missing/retired fixture leaves its delegated row.
          accountable.destroy! if accountable.class.exists?(accountable.id)
          family.ibkr_items.each do |item|
            item.ibkr_accounts.delete_all
            item.delete
          end
          family.destroy!
          clear_enqueued_jobs
        end
      end
    end
end

class Account::SyncerNativeOwnerAdmissionTest < ActiveSupport::TestCase
  include AccountSyncInputTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  teardown { clear_enqueued_jobs }

  test "native history rejects owner deletion scheduling during market data before retaining preparation" do
    with_account_input do
      seed_account_history
      sync = enqueue_account_handoff
      sync.start!
      before = @account.entries.order(:id).map(&:attributes)
      original_seal = sync.attributes.slice("account_inputs_sealed_at", "account_inputs_digest", "parent_id", "predecessor_id")
      account_id = @account.id
      transactions = []
      importer = Object.new
      importer.define_singleton_method(:import_all) do
        transactions << ApplicationRecord.connection.open_transactions
        Account.where(id: account_id).update_all(status: "pending_deletion")
      end
      Account::MarketDataImporter.expects(:new).returns(importer)

      assert_no_difference [ "Balance.count", "Holding.count", "IngestionBatch.count", "Account::SyncPreparation.count" ] do
        assert_raises(Account::SyncAdmission::Unavailable) { Account::Syncer.new(@account).perform_sync(sync) }
      end

      assert_equal [ 0 ], transactions
      assert_equal before, @account.entries.order(:id).map(&:attributes)
      assert_equal original_seal, sync.reload.attributes.slice(*original_seal.keys)
      assert_nil sync.account_materialized_at
      assert_nil sync.account_sync_preparation
    ensure
      Account.where(id: @account.id).update_all(status: "active") if @account
    end
  end
end
