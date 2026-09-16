require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class QuestradeItem::LegacyAccessTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Access = QuestradeItem::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    Sentry.stubs(:capture_exception)
    Account.any_instance.stubs(:sync_later)
    Account.any_instance.stubs(:broadcast_sync_complete)
  end

  teardown { clear_enqueued_jobs }

  test "all direct processors and snapshots refuse transitional or native ownership before effects" do
    with_source do |item, source, account, _link, _security|
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "questrade", legacy_type: "QuestradeItem", legacy_id: item.id)
      operations = [
        -> { QuestradeAccount::Processor.new(source).process },
        -> { QuestradeAccount::ActivitiesProcessor.new(source).process },
        -> { QuestradeAccount::HoldingsProcessor.new(source).process },
        -> { source.upsert_from_questrade!(number: "123", type: "Margin") },
        -> { source.upsert_holdings_snapshot!([ position ]) },
        -> { source.upsert_activities_snapshot!([ trade ]) },
        -> { source.upsert_balances!([ { currency: "CAD", cash: 500 } ]) },
        -> { item.questrade_accounts.build(questrade_account_id: "456").upsert_from_questrade!(number: "456", type: "Cash") }
      ]
      before = source.attributes
      %w[quiescing active retired rollback_pending].each do |state|
        control.update!(state: state)
        assert_no_difference [ "QuestradeAccount.count", "Entry.count", "Holding.count" ] do
          operations.each { |operation| assert_raises(Fence::OwnershipChanged, &operation) }
        end
      end
      assert_equal before, source.reload.attributes
      assert_equal BigDecimal("10"), account.reload.balance
    end
  end

  test "security resolution stays outside publication while exact positions cash trades fees and anchors persist" do
    with_source do |item, source, account, link, security|
      source.update!(raw_holdings_payload: [ position ], raw_activities_payload: [ trade, deposit ],
        raw_balances_payload: [ { currency: "CAD", cash: 50 }, { currency: "USD", cash: 12 } ])
      lookups = []
      resolver = lambda do |*_args|
        lookups << ApplicationRecord.connection.open_transactions
        assert_equal :busy, drain_elsewhere(item)
        security
      end
      QuestradeAccount::HoldingsProcessor.any_instance.stubs(:resolve_security).with { |*args| resolver.call(*args); true }.returns(security)
      QuestradeAccount::ActivitiesProcessor.any_instance.stubs(:resolve_security).with { |*args| resolver.call(*args); true }.returns(security)
      checked = []
      verifier = lambda do |fresh, financial|
        checked << [ fresh.id, financial.id, ApplicationRecord.connection.open_transactions ]
      end

      result = QuestradeAccount::Processor.new(source, publication_verifier: verifier).process

      assert_equal({ holdings_processed: true, activities_processed: true }, result)
      assert_equal [ 0, 0 ], lookups
      assert checked.all? { |source_id, account_id, count| source_id == source.id && account_id == account.id && count.positive? }
      assert_equal BigDecimal("300"), account.reload.balance
      assert_equal BigDecimal("50"), account.cash_balance
      assert_equal BigDecimal("300"), account.current_anchor_balance
      holding = account.holdings.find_by!(external_id: "questrade_123_789_#{Date.current}")
      assert_equal [ BigDecimal("2.5"), BigDecimal("100"), BigDecimal("250"), BigDecimal("80") ],
        [ holding.qty, holding.price, holding.amount, holding.cost_basis ]
      assert_equal link.id, holding.account_provider_id
      cash = account.holdings.find_by!(external_id: "questrade_cash_usd_#{Date.current}")
      assert_equal [ BigDecimal("12"), BigDecimal("1"), "USD", link.id ], [ cash.qty, cash.price, cash.currency, cash.account_provider_id ]
      assert_equal 1, account.entries.where(source: "questrade", entryable_type: "Trade").count
      assert_equal [ BigDecimal("-25"), BigDecimal("2") ], account.entries.where(source: "questrade", entryable_type: "Transaction").order(:amount).pluck(:amount)
      assert_equal :drained, drain_elsewhere(item)
    end
  end

  test "relink or replacement AP during security resolution cannot move or recreate a holding" do
    [ :relink, :replace ].each do |change|
      with_source do |item, source, account, link, security|
        source.update!(raw_holdings_payload: [ position ])
        future = account.holdings.create!(security: security, account_provider: link, external_id: "future",
          date: Date.current + 1, currency: "CAD", qty: 1, price: 40, amount: 40)
        before = future.attributes
        other = create_account(item.family, "Other")
        QuestradeAccount::HoldingsProcessor.any_instance.stubs(:resolve_security).with do |*_args|
          assert_equal 0, ApplicationRecord.connection.open_transactions
          if change == :relink
            AccountProvider.find(link.id).update!(account: other)
          else
            AccountProvider.find(link.id).destroy!
            AccountProvider.create!(account: account, provider: QuestradeAccount.find(source.id))
          end
          true
        end.returns(security)

        assert_raises(Fence::OwnershipChanged) { QuestradeAccount::HoldingsProcessor.new(source).process }

        # AP deletion nullifies the old association; the processor itself does
        # not prune this future observation or create a replacement position.
        expected = change == :replace ? before.merge("account_provider_id" => nil) : before
        assert_equal expected, future.reload.attributes
        assert_equal [ future.id ], account.holdings.pluck(:id)
        assert_empty other.holdings
      end
    end
  end

  test "changed source snapshot or remote identity during lookup refuses both trade and commission" do
    [ :payload, :remote ].each do |change|
      with_source do |_item, source, account, _link, security|
        source.update!(raw_activities_payload: [ trade ])
        QuestradeAccount::ActivitiesProcessor.any_instance.stubs(:resolve_security).with do |*_args|
          assert_equal 0, ApplicationRecord.connection.open_transactions
          values = change == :payload ? { raw_activities_payload: [ deposit ] } : { questrade_account_id: "changed" }
          QuestradeAccount.find(source.id).update!(values)
          true
        end.returns(security)

        assert_raises(Fence::OwnershipChanged) { QuestradeAccount::ActivitiesProcessor.new(source).process }
        assert_empty account.entries
      end
    end
  end

  test "a cancelled publication verifier denies before writes and is never swallowed by partial processing" do
    with_source do |_item, source, account, _link, _security|
      source.update!(raw_activities_payload: [ deposit ], raw_holdings_payload: [ position ])
      before = source.attributes
      verifier = ->(_fresh, _financial) { raise Fence::OwnershipChanged, "original request cancelled" }
      assert_raises(Fence::OwnershipChanged) { QuestradeAccount::ActivitiesProcessor.new(source, publication_verifier: verifier).process }
      assert_raises(Fence::OwnershipChanged) { QuestradeAccount::HoldingsProcessor.new(source, publication_verifier: verifier).process }
      assert_raises(Fence::OwnershipChanged) { QuestradeAccount::Processor.new(source, publication_verifier: verifier).process }
      assert_raises(Fence::OwnershipChanged) { source.upsert_activities_snapshot!([ trade ], mark_synced: false, publication_verifier: verifier) }
      assert_equal before, source.reload.attributes
      assert_empty account.entries
      assert_empty account.holdings
      assert_equal BigDecimal("10"), account.reload.balance
    end
  end

  test "trade and commission roll back together and strict retry preserves original economic identity" do
    with_source do |_item, source, account, _link, _security|
      source.update!(raw_activities_payload: [ trade ])
      callback = ->(_transaction) { raise IOError, "commission persistence failed" }
      Transaction.set_callback(:create, :after, callback)
      begin
        assert_no_difference [ "Entry.count", "Trade.count", "Transaction.count" ] do
          assert_raises(IOError) { QuestradeAccount::ActivitiesProcessor.new(source, raise_on_error: true).process }
        end
      ensure
        Transaction.skip_callback(:create, :after, callback)
      end
      assert_empty account.entries
      processor = QuestradeAccount::ActivitiesProcessor.new(source, raise_on_error: true)
      assert_equal({ trades: 1, transactions: 1 }, processor.process)
      identities = account.entries.order(:id).pluck(:id, :external_id, :amount, :currency, :date)
      processor.process
      assert_equal identities, account.entries.order(:id).pluck(:id, :external_id, :amount, :currency, :date)
    end
  end

  test "holding callback failure keeps future rows and manual cost basis and allows retry" do
    with_source do |_item, source, account, link, security|
      source.update!(raw_holdings_payload: [ position ])
      existing = account.holdings.create!(security: security, account_provider: link,
        external_id: "questrade_123_789_#{Date.current}", date: Date.current, currency: "CAD", qty: 1, price: 40, amount: 40,
        cost_basis: 7, cost_basis_source: "manual", cost_basis_locked: true)
      future = account.holdings.create!(security: security, account_provider: link, external_id: "future",
        date: Date.current + 1, currency: "CAD", qty: 1, price: 40, amount: 40)
      before = [ existing.attributes, future.attributes ]
      callback = ->(holding) { raise IOError, "holding callback failed" if holding.id == existing.id }
      Holding.set_callback(:update, :after, callback)
      begin
        QuestradeAccount::HoldingsProcessor.new(source).process
      ensure
        Holding.skip_callback(:update, :after, callback)
      end
      assert_equal before, [ existing.reload.attributes, future.reload.attributes ]
      QuestradeAccount::HoldingsProcessor.new(source).process
      assert_equal BigDecimal("2.5"), existing.reload.qty
      assert_equal BigDecimal("7"), existing.cost_basis
      assert existing.cost_basis_locked?
      assert_equal before.last, future.reload.attributes
    end
  end

  test "a competing financial row lock refuses promptly and releases the migration permit" do
    with_source do |item, source, account, _link, _security|
      with_locked_account(account) do
        assert_raises(Fence::Busy) { QuestradeAccount::Processor.new(source).process }
        assert_raises(Fence::Busy) { source.upsert_balances!([ { currency: "CAD", cash: 999 } ]) }
      end
      assert_equal BigDecimal("10"), account.reload.balance
      assert_equal BigDecimal("50"), source.reload.cash_balance
      assert_equal :drained, drain_elsewhere(item)
      QuestradeAccount::Processor.new(source).process
      assert_equal BigDecimal("300"), account.reload.balance
    end
  end

  test "snapshot staging can preserve progress and checks the exact captured link and cache" do
    with_source do |item, source, account, link, _security|
      captured = Access.capture_context(source)
      checks = []
      verifier = lambda do |fresh, financial|
        checks << [ fresh.id, financial.id, ApplicationRecord.connection.open_transactions.positive? ]
      end
      source.upsert_activities_snapshot!([ deposit ], mark_synced: false, expected_context: captured, publication_verifier: verifier)
      assert_nil source.last_activities_sync
      assert_equal [ deposit ], source.raw_activities_payload
      assert_equal [ [ source.id, account.id, true ] ], checks
      assert_raises(Fence::OwnershipChanged) { source.upsert_activities_snapshot!([ trade ], expected_context: captured) }
      captured = Access.capture_context(source)
      other = create_account(item.family, "Relinked")
      link.update!(account: other)
      assert_raises(Fence::OwnershipChanged) { source.upsert_balances!([ { currency: "CAD", cash: 999 } ], expected_context: captured) }
      assert_equal BigDecimal("50"), source.reload.cash_balance
      assert_nil source.last_activities_sync
    end
  end

  test "public importer cannot stage a balance response onto a link replaced during HTTP" do
    with_source do |item, source, account, link, _security|
      api = "https://api01.iq.questrade.com"
      replacement = create_account(item.family, "New financial owner")
      stub_request(:post, Provider::Questrade::LOGIN_URL).to_return(status: 200,
        body: { access_token: "access", refresh_token: "rotated", api_server: "#{api}/", expires_in: 1800 }.to_json)
      stub_request(:get, "#{api}/v1/accounts").to_return(status: 200,
        body: { accounts: [ { number: "123", type: "Margin", status: "Active" } ] }.to_json)
      stub_request(:get, "#{api}/v1/accounts/123/balances").to_return do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal :busy, drain_elsewhere(item)
        AccountProvider.find(link.id).update!(account: replacement)
        { status: 200, body: { perCurrencyBalances: [ { currency: "CAD", cash: 900 } ],
          combinedBalances: [ { currency: "CAD", totalEquity: 999 } ] }.to_json }
      end

      assert_raises(Fence::OwnershipChanged) { QuestradeItem::Importer.new(item).import }

      assert_equal BigDecimal("50"), source.reload.cash_balance
      assert_equal BigDecimal("300"), source.current_balance
      assert_equal BigDecimal("10"), account.reload.balance
      assert_equal BigDecimal("10"), replacement.reload.balance
      assert_nil source.raw_balances_payload
      assert_not_requested :get, "#{api}/v1/accounts/123/positions"
    end
  end

  test "a balance callback failure rolls back the account and its anchor before retry" do
    with_source do |_item, source, account, _link, _security|
      callback = ->(valuation) { raise IOError, "anchor callback failure" if valuation.current_anchor? }
      Valuation.set_callback(:create, :after, callback)
      begin
        assert_raises(ActiveRecord::RecordNotSaved) { QuestradeAccount::Processor.new(source).process }
      ensure
        Valuation.skip_callback(:create, :after, callback)
      end
      assert_equal BigDecimal("10"), account.reload.balance
      assert_empty account.entries
      QuestradeAccount::Processor.new(source).process
      assert_equal BigDecimal("300"), account.reload.balance
      assert_equal BigDecimal("300"), account.current_anchor_balance
    end
  end

  test "unlinked discovery and snapshots remain available but cannot impersonate a different remote account" do
    with_source do |item, source, account, link, _security|
      link.destroy!
      source.reload
      assert_nil QuestradeAccount::Processor.new(source).process
      source.upsert_balances!([ { currency: "USD", cash: 500 } ])
      assert_equal "USD", source.currency
      assert_equal BigDecimal("500"), source.cash_balance
      assert_equal BigDecimal("10"), account.reload.balance
      assert_raises(Fence::OwnershipChanged) { source.upsert_from_questrade!(number: "wrong", type: "Margin") }
      new_source = item.questrade_accounts.build(questrade_account_id: "456")
      new_source.upsert_from_questrade!(number: "456", type: "Cash")
      assert new_source.persisted?
      assert_equal "Cash (456)", new_source.reload.name
      assert_equal item.id, new_source.questrade_item_id
    end
  end

  test "a pending financial account or deleted source refuses without balance or snapshot changes" do
    with_source do |_item, source, account, _link, _security|
      account.update!(status: :pending_deletion)
      before = source.attributes
      assert_raises(Fence::OwnershipChanged) { QuestradeAccount::Processor.new(source).process }
      assert_raises(Fence::OwnershipChanged) { source.upsert_holdings_snapshot!([ position ]) }
      assert_equal before, source.reload.attributes
      account.update!(status: :active)
      QuestradeAccount.where(id: source.id).delete_all
      assert_raises(Fence::OwnershipChanged) { QuestradeAccount::ActivitiesProcessor.new(source).process }
      assert_equal BigDecimal("10"), account.reload.balance
    end
  end

  private

    def with_source
      with_provider_encryption do
        family = Family.create!(name: "Questrade publication")
        item = family.questrade_items.create!(name: "Questrade", refresh_token: "fixture-token")
        source = item.questrade_accounts.create!(questrade_account_id: "123", name: "Margin", currency: "CAD", current_balance: 300, cash_balance: 50)
        account = create_account(family, "Margin")
        link = AccountProvider.create!(account: account, provider: source)
        @ticker = "QTP#{SecureRandom.hex(6).upcase}"
        security = Security.create!(ticker: @ticker, name: "Questrade test security", offline: true)
        cash_ticker = "CASH-#{account.id}-USD".upcase
        yield item, source, account, link, security
      ensure
        if family
          ProviderMigrationControl.where(family: family).delete_all
          Sync.where(syncable_type: "QuestradeItem", syncable_id: family.questrade_items.select(:id)).delete_all
          family.accounts.each { |financial| financial.holdings.destroy_all }
          AccountProvider.where(account_id: family.accounts.select(:id)).destroy_all
          family.accounts.each(&:destroy!)
          family.questrade_items.destroy_all
          family.destroy!
        end
        security&.destroy!
        Security.where(ticker: cash_ticker).destroy_all if cash_ticker
      end
    end

    def create_account(family, name)
      family.accounts.create!(name: name, balance: 10, currency: "CAD", accountable: Investment.new)
    end

    def position
      { "symbol" => @ticker, "symbolId" => 789, "openQuantity" => "2.5", "currentPrice" => "100",
        "currentMarketValue" => "250", "averageEntryPrice" => "80", "currency" => "CAD" }
    end

    def trade
      { "type" => "Trades", "action" => "Buy", "symbol" => @ticker, "symbolId" => 789, "quantity" => "2.5", "price" => "100",
        "netAmount" => "-252", "commission" => "2", "transactionDate" => "2026-09-01", "tradeDate" => "2026-09-01", "currency" => "CAD", "description" => "Buy position" }
    end

    def deposit
      { "type" => "Deposits", "netAmount" => "25", "transactionDate" => "2026-09-01", "currency" => "CAD", "description" => "Cash deposit" }
    end

    def drain_elsewhere(item)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new do
        Fence.with_exclusive(item) { :drained }
      rescue Fence::Busy
        :busy
      end
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end

    def with_locked_account(account)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      ready, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Account.transaction do
            Account.where(id: account.id).lock("FOR UPDATE").take!
            ready << true
            release.pop
          end
        end
      rescue Exception => error
        ready << error
        raise
      end
      message = Timeout.timeout(5) { ready.pop }
      raise message if message.is_a?(Exception)
      yield
    ensure
      release << true if release
      Timeout.timeout(5) { worker&.join }
      worker&.kill if worker&.alive?
    end
end
