require "test_helper"
require "timeout"
require_relative "../../../support/provider_ingestion_test_helper"

class SimplefinAccount::Liabilities::CreditPublicationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false
  Fence = Provider::AccountData::LegacyWriterFence
  Processor = SimplefinAccount::Liabilities::CreditProcessor

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "admitted publication reloads credit payload and retains unrelated financial values" do
    with_source do |item, source, account|
      source.current_account
      processor = Processor.new(source)
      original = SimplefinItem::LegacyAccess.method(:with_publication)
      admitted = lambda do |selected, expected_account:, &block|
        SimplefinAccount.find(source.id).update!(raw_payload: { "available-balance" => "2500.75" })
        original.call(selected, expected_account: expected_account) do |fresh, financial|
          assert_operator ApplicationRecord.connection.open_transactions, :>=, 1
          refute_same selected, fresh
          assert_same financial, fresh.current_account
          block.call(fresh, financial)
        end
      end

      assert_no_difference [ "DataEnrichment.count", "Entry.count", "Balance.count", "AccountProvider.count" ] do
        SimplefinItem::LegacyAccess.stub(:with_publication, admitted) { assert processor.process }
      end
      credit = account.reload.accountable.reload
      assert_equal BigDecimal("2500.75"), credit.available_credit
      assert_equal BigDecimal("29.95"), credit.annual_fee
      assert_equal BigDecimal("15"), credit.minimum_payment
      assert_equal BigDecimal("100"), account.balance
      assert_equal "USD", account.currency
      assert_equal "1000.25", source.raw_payload.fetch("available-balance")
      assert_equal item.id, source.simplefin_item_id
    end
  end

  test "unlinked and noncredit sources skip financial publication" do
    [ :unlinked, :noncredit ].each do |state|
      with_source do |_item, source, account|
        credit = account.accountable
        state == :unlinked ? account.account_providers.destroy_all : account.update!(accountable: Depository.new)
        SimplefinItem::LegacyAccess.expects(:with_publication).never
        assert_no_difference "DataEnrichment.count" do
          assert_nil Processor.new(source).process
        end
        assert_equal BigDecimal("200"), credit.reload.available_credit
      end
    end
  end

  test "missing and nonpositive available values retain the existing credit amount" do
    with_source do |_item, source, account|
      Account::ProviderImportAdapter.any_instance.expects(:update_accountable_attributes).never
      [ nil, "", "0", "-10" ].each do |value|
        source.update!(raw_payload: { "available-balance" => value })
        assert_no_difference "DataEnrichment.count" { assert_nil Processor.new(source).process }
        assert_equal BigDecimal("200"), account.accountable.reload.available_credit
      end
    end
  end

  test "unlink or relink after owner selection cannot update either credit card" do
    [ :unlink, :relink ].each do |change|
      with_source do |item, source, account|
        other = Account.create!(family: item.family, name: "Other credit", currency: "USD", balance: 75,
          accountable: CreditCard.new(available_credit: 900))
        link = account.account_providers.sole
        original = SimplefinItem::LegacyAccess.method(:with_publication)
        changed = lambda do |selected, expected_account:, &block|
          change == :unlink ? link.destroy! : link.update!(account: other)
          original.call(selected, expected_account: expected_account, &block)
        end
        Account::ProviderImportAdapter.any_instance.expects(:update_accountable_attributes).never
        assert_no_difference "DataEnrichment.count" do
          SimplefinItem::LegacyAccess.stub(:with_publication, changed) do
            assert_raises(Fence::OwnershipChanged) { Processor.new(source).process }
          end
        end
        assert_equal BigDecimal("200"), account.accountable.reload.available_credit
        assert_equal BigDecimal("900"), other.accountable.reload.available_credit
      end
    end
  end

  test "currency delegated type and delegated identity drift reject before enrichment or credit mutation" do
    [ :currency, :type, :identity ].each do |change|
      with_source do |_item, source, account|
        credit = account.accountable
        replacement = change == :type ? Depository.create! : CreditCard.create!(available_credit: 900)
        original = SimplefinItem::LegacyAccess.method(:with_publication)
        changed = lambda do |selected, expected_account:, &block|
          attributes = case change
          when :currency then { currency: "EUR" }
          when :type then { accountable_type: "Depository", accountable_id: replacement.id }
          when :identity then { accountable_id: replacement.id }
          end
          Account.where(id: account.id).update_all(attributes)
          original.call(selected, expected_account: expected_account, &block)
        end
        Account::ProviderImportAdapter.any_instance.expects(:update_accountable_attributes).never
        assert_no_difference "DataEnrichment.count" do
          SimplefinItem::LegacyAccess.stub(:with_publication, changed) do
            assert_raises(Fence::OwnershipChanged) { Processor.new(source).process }
          end
        end
        assert_equal BigDecimal("200"), credit.reload.available_credit
        assert_equal BigDecimal("900"), replacement.reload.available_credit if replacement.is_a?(CreditCard)
      ensure
        replacement&.delete unless Account.where(accountable_type: replacement&.class&.name, accountable_id: replacement&.id).exists?
      end
    end
  end

  test "a reparented foreign source cannot broaden the original item permit" do
    with_source do |item, source, account|
      source.simplefin_item
      foreign_family = Family.create!(name: "Foreign SimpleFIN credit")
      foreign_item = SimplefinItem.create!(family: foreign_family, name: "Foreign source", access_url: "https://example.com/foreign")
      SimplefinAccount.where(id: source.id).update_all(simplefin_item_id: foreign_item.id)
      Account::ProviderImportAdapter.any_instance.expects(:update_accountable_attributes).never
      assert_no_difference "DataEnrichment.count" do
        assert_raises(Fence::OwnershipChanged) { Processor.new(source).process }
      end
      assert_equal BigDecimal("200"), account.accountable.reload.available_credit
    ensure
      SimplefinAccount.where(id: source&.id).update_all(simplefin_item_id: item.id) if item
      foreign_item&.destroy!
      foreign_family&.destroy!
    end
  end

  test "quiescing and native ownership reject credit publication before account effects" do
    with_source do |item, source, account|
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin", legacy_type: "SimplefinItem", legacy_id: item.id)
      Account::ProviderImportAdapter.any_instance.expects(:update_accountable_attributes).never
      %w[quiescing active].each do |state|
        control.update!(state: state)
        assert_no_difference "DataEnrichment.count" do
          assert_raises(Fence::OwnershipChanged) { Processor.new(source).process }
        end
        assert_equal BigDecimal("200"), account.accountable.reload.available_credit
      end
    end
  end

  test "an account locked in another session defers before changing credit or enrichment" do
    with_source do |_item, source, account|
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      entered, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Account.transaction do
            Account.lock.find(account.id)
            entered << true
            release.pop
          end
        end
      end
      Timeout.timeout(5) { entered.pop }
      assert_no_difference "DataEnrichment.count" do
        assert_raises(Fence::Busy) { Processor.new(source).process }
      end
      assert_equal BigDecimal("200"), account.accountable.reload.available_credit
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end
  end

  test "publication failure rolls back a credit update before returning to the caller" do
    with_source do |_item, source, account|
      original = SimplefinItem::LegacyAccess.method(:with_publication)
      failed = lambda do |selected, expected_account:, &block|
        original.call(selected, expected_account: expected_account) do |fresh, financial|
          assert block.call(fresh, financial)
          assert_equal BigDecimal("1000.25"), financial.accountable.reload.available_credit
          raise IOError, "Simulated failure after credit publication"
        end
      end
      assert_no_difference "DataEnrichment.count" do
        SimplefinItem::LegacyAccess.stub(:with_publication, failed) do
          assert_raises(IOError) { Processor.new(source).process }
        end
      end
      assert_equal BigDecimal("200"), account.accountable.reload.available_credit
    end
  end

  test "a rescued credit after-update error returns false without committing its already-issued SQL" do
    with_source do |_item, source, account|
      credit_id = account.accountable_id
      observed = []
      failed = lambda do |credit|
        if credit.id == credit_id
          observed << CreditCard.where(id: credit_id).pick(:available_credit)
          raise IOError, "Simulated credit callback failure"
        end
      end
      CreditCard.set_callback(:update, :after, failed)
      begin
        assert_no_difference "DataEnrichment.count" do
          assert_equal false, Processor.new(source).process
        end
      ensure
        CreditCard.skip_callback(:update, :after, failed)
      end
      assert_equal [ BigDecimal("1000.25") ], observed
      assert_equal BigDecimal("200"), account.accountable.reload.available_credit
    end
  end

  private
    def with_source
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN credit publication")
        item = SimplefinItem.create!(family: family, name: "SimpleFIN", access_url: "https://example.com/access")
        source = item.simplefin_accounts.create!(name: "Credit source", account_id: SecureRandom.uuid,
          currency: "USD", account_type: "credit", current_balance: -100, raw_payload: { "available-balance" => "1000.25" })
        credit = CreditCard.new(available_credit: 200, annual_fee: "29.95", minimum_payment: 15)
        account = Account.create!(family: family, name: "Credit account", currency: "USD", balance: 100, accountable: credit)
        AccountProvider.create!(account: account, provider: source)
        yield item, source, account
      ensure
        if family&.persisted?
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          ProviderMigrationControl.where(family: family).delete_all
          family.accounts.reload.each(&:destroy!)
          CreditCard.find_by(id: credit&.id)&.destroy!
          item&.reload&.destroy!
          family.destroy!
        end
      end
    end
end
