require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class SimplefinAccount::BalancePublicationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence
  Stage = Struct.new(:callback, :skipped_entries, keyword_init: true) do
    def process
      callback.call
    end
  end

  test "loan balances retain absolute debt normalization and posted balance precedence" do
    SimplefinAccount::Liabilities::OverpaymentAnalyzer.expects(:new).never
    [ [ "145.67", "200", "145.67" ], [ "-145.67", "-200", "145.67" ],
      [ "0", "-200", "0" ], [ nil, "-65.43", "65.43" ] ].each do |balance, available, expected|
      with_source(accountable: Loan.new, balance: balance, available: available) do |_item, source, account|
        SimplefinAccount::Processor.new(source).process

        assert_equal BigDecimal(expected), account.reload.balance
        assert_equal BigDecimal(expected), account.cash_balance
        assert_equal "USD", account.currency
      end
    end
  end

  test "credit card debt and overpayment retain the real history classifier and sticky hint" do
    settings = {
      "simplefin_cc_overpayment_detection" => "true", "simplefin_cc_overpayment_window_days" => "120",
      "simplefin_cc_overpayment_min_txns" => "2", "simplefin_cc_overpayment_min_payments" => "1",
      "simplefin_cc_overpayment_epsilon_base" => "0.50", "simplefin_cc_overpayment_statement_guard_days" => "0",
      "simplefin_cc_overpayment_sticky_days" => "7"
    }
    settings.each { |key, value| Setting.stubs(:[]).with(key).returns(value) }
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      [ [ "120", "-40", "80", "debt" ], [ "50", "-130", "-80", "credit" ] ].each do |charge, payment, expected, hint|
        with_source(accountable: CreditCard.new, balance: "-80") do |_item, source, account|
          account.entries.create!(name: "Charge", date: 10.days.ago.to_date, amount: BigDecimal(charge),
            currency: "USD", entryable: Transaction.new)
          account.entries.create!(name: "Payment", date: 8.days.ago.to_date, amount: BigDecimal(payment),
            currency: "USD", entryable: Transaction.new)

          assert_no_difference [ "Entry.count", "Transaction.count" ] { SimplefinAccount::Processor.new(source).process }

          assert_equal BigDecimal(expected), account.reload.balance
          assert_equal BigDecimal(expected), account.cash_balance
          assert_equal hint, Rails.cache.read("simplefin:sfa:#{source.id}:liability_sign_hint").fetch(:value)
        end
      end
    end
  ensure
    Setting.unstub(:[])
  end

  test "investment cash keeps money market exclusions and margin while downstream stages run after balance commit" do
    with_source(accountable: Investment.new, balance: "1000.25") do |_item, source, account|
      source.update!(raw_holdings_payload: [
        { "symbol" => "TEST_EQUITY", "market_value" => "1200.25" },
        { "symbol" => "TEST_CASH", "market_value" => "400" }
      ])
      settings = Rails.configuration.x.simplefin
      previous_tickers, previous_patterns = settings.money_market_tickers, settings.money_market_patterns
      settings.money_market_tickers, settings.money_market_patterns = [ "TEST_CASH" ], []
      stages = []
      skipped = [ { id: SecureRandom.uuid, reason: "user_modified" } ]
      probe = lambda do |name|
        Stage.new(skipped_entries: name == :transactions ? skipped : [], callback: lambda do
          assert_equal 0, ApplicationRecord.connection.open_transactions
          assert_equal BigDecimal("1000.25"), account.reload.balance
          assert_equal BigDecimal("-200"), account.cash_balance
          stages << name
        end)
      end
      SimplefinAccount::Transactions::Processor.expects(:new).once.returns(probe.call(:transactions))
      SimplefinAccount::Investments::TransactionsProcessor.expects(:new).once.returns(probe.call(:investment_transactions))
      SimplefinAccount::Investments::HoldingsProcessor.expects(:new).once.returns(probe.call(:holdings))

      processor = SimplefinAccount::Processor.new(source)
      processor.process

      assert_equal [ :transactions, :investment_transactions, :holdings ], stages
      assert_equal skipped, processor.skipped_entries
      assert_equal BigDecimal("1000.25"), account.reload.balance
      assert_equal BigDecimal("-200"), account.cash_balance
    ensure
      if settings
        settings.money_market_tickers, settings.money_market_patterns = previous_tickers, previous_patterns
      end
    end
  end

  test "a relink after financial owner selection rejects balance publication and later stages" do
    with_source(balance: "250") do |item, source, account|
      other = item.family.accounts.create!(name: "Other owner", currency: "USD", balance: 19,
        cash_balance: 19, accountable: Depository.new)
      before = [ account, other ].map(&:attributes)
      link = account.account_providers.sole
      original = SimplefinItem::LegacyAccess.method(:with_publication)
      changed = lambda do |selected, expected_account:, &block|
        link.update!(account: other)
        original.call(selected, expected_account: expected_account, &block)
      end
      SimplefinAccount::Transactions::Processor.expects(:new).never
      SimplefinAccount::Investments::HoldingsProcessor.expects(:new).never

      assert_no_difference [ "Entry.count", "Holding.count" ] do
        SimplefinItem::LegacyAccess.stub(:with_publication, changed) do
          assert_raises(Fence::OwnershipChanged) { SimplefinAccount::Processor.new(source).process }
        end
      end

      assert_equal before, [ account, other ].map { |record| record.reload.attributes }
      assert_equal other.id, source.reload.current_account.id
    end
  end

  test "a failed balance publication rolls back inside an admitted caller that rescues and continues" do
    with_source(balance: "250") do |item, source, account|
      before = account.attributes
      original = SimplefinItem::LegacyAccess.method(:with_publication)
      failed = lambda do |selected, expected_account:, &block|
        original.call(selected, expected_account: expected_account) do |fresh, financial|
          block.call(fresh, financial)
          assert_equal BigDecimal("250"), Account.find(financial.id).balance
          raise IOError, "Simulated failure after balance write"
        end
      end
      SimplefinAccount::Transactions::Processor.expects(:new).never
      SimplefinAccount::Investments::HoldingsProcessor.expects(:new).never

      Fence.with_item(item, operation: :publish) do
        Account.transaction do
          SimplefinItem::LegacyAccess.stub(:with_publication, failed) do
            assert_raises(IOError) { SimplefinAccount::Processor.new(source).process }
          end
          assert_equal before, account.reload.attributes
          source.update!(name: "Outer caller continued")
        end
      end

      assert_equal before, account.reload.attributes
      assert_equal "Outer caller continued", source.reload.name
    end
  end

  test "an independent transaction-stage failure retains the committed balance and permits later stages" do
    with_source(accountable: Investment.new, balance: "375.50") do |_item, source, account|
      stages = []
      transactions = Stage.new(skipped_entries: [], callback: lambda do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal BigDecimal("375.50"), account.reload.balance
        stages << :transactions
        raise IOError, "Independent transaction stage failed"
      end)
      later = lambda do |name|
        Stage.new(skipped_entries: [], callback: lambda do
          assert_equal 0, ApplicationRecord.connection.open_transactions
          stages << name
        end)
      end
      SimplefinAccount::Transactions::Processor.expects(:new).once.returns(transactions)
      SimplefinAccount::Investments::TransactionsProcessor.expects(:new).once.returns(later.call(:investment_transactions))
      SimplefinAccount::Investments::HoldingsProcessor.expects(:new).once.returns(later.call(:holdings))
      Sentry.expects(:capture_exception).once

      processor = SimplefinAccount::Processor.new(source)
      processor.process

      assert_equal [ :transactions, :investment_transactions, :holdings ], stages
      assert_empty processor.skipped_entries
      assert_equal BigDecimal("375.50"), account.reload.balance
      assert_equal BigDecimal("375.50"), account.cash_balance
    end
  end

  private
    def with_source(accountable: Depository.new, balance: "100", available: nil)
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN balance publication")
        item = SimplefinItem.create!(family: family, name: "SimpleFIN", access_url: "https://example.com/balance")
        source = item.simplefin_accounts.create!(name: "Source account", account_id: SecureRandom.uuid,
          currency: "USD", account_type: "checking", current_balance: balance, available_balance: available,
          raw_transactions_payload: [], raw_holdings_payload: [], raw_payload: {})
        account = family.accounts.create!(name: "Existing financial account", currency: "USD", balance: 7,
          cash_balance: 7, accountable: accountable)
        AccountProvider.create!(account: account, provider: source)
        yield item, source, account
      ensure
        if family&.persisted?
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          family.accounts.reload.each(&:destroy!)
          item&.reload&.destroy!
          family.destroy!
        end
      end
    end
end
