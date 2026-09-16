require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class SimplefinItem::LegacyAccessTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "all direct financial entrypoints reject nonlegacy owners before any side effect" do
    with_source do |item, source, account|
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin",
        legacy_type: "SimplefinItem", legacy_id: item.id)
      before = [ item, source, account ].map(&:attributes)
      operations = [
        -> { SimplefinAccount::Processor.new(source).process },
        -> { SimplefinAccount::Transactions::Processor.new(source).process },
        -> { SimplefinEntry::Processor.new(transaction, simplefin_account: source).process },
        -> { SimplefinAccount::Investments::HoldingsProcessor.new(source).process },
        -> { SimplefinAccount::Liabilities::CreditProcessor.new(source).process },
        -> { source.ensure_account_provider! }
      ]
      %w[quiescing active rollback_pending retired].each do |state|
        control.update!(state: state)
        assert_no_difference [ "Entry.count", "Holding.count", "AccountProvider.count" ] do
          operations.each { |operation| assert_raises(Fence::OwnershipChanged, &operation) }
        end
        assert_equal before, [ item, source, account ].map { |record| record.reload.attributes }
      end
    end
  end

  test "transaction processing reloads cached payloads and preserves financial normalization" do
    with_source do |_item, source, account|
      source.update!(raw_transactions_payload: [ transaction.merge(id: "stale") ])
      processor = SimplefinAccount::Transactions::Processor.new(source)
      SimplefinAccount.find(source.id).update!(raw_transactions_payload: [ transaction ])

      assert_difference "account.entries.count", 1 do
        processor.process
      end

      entry = account.entries.find_by!(source: "simplefin", external_id: "simplefin_current")
      assert_equal BigDecimal("12.34"), entry.amount
      assert_equal "USD", entry.currency
      assert_equal Date.new(2026, 9, 2), entry.date
      assert_not account.entries.exists?(external_id: "simplefin_stale")
      assert_empty processor.skipped_entries
      assert_equal "stale", source.raw_transactions_payload.sole.fetch("id")
    end
  end

  test "a stale cached account cannot recreate its link after unlink" do
    with_source do |_item, source, account|
      account.update!(simplefin_account_id: source.id)
      assert_equal account.id, source.current_account.id
      account.account_providers.delete_all
      Account.find(account.id).update!(simplefin_account_id: nil)

      assert_no_difference "AccountProvider.count" do
        assert_nil source.ensure_account_provider!
      end
      assert_nil account.reload.simplefin_account_id
    end
  end

  test "direct and AccountProvider disagreement fails before a balance or transaction write" do
    with_source do |item, source, account|
      other = Account.create!(family: item.family, name: "Other account", currency: "USD", balance: 20,
        accountable: Depository.new, simplefin_account_id: source.id)
      before = [ account, other ].map(&:attributes)

      assert_no_difference "Entry.count" do
        assert_raises(Fence::OwnershipChanged) { SimplefinAccount::Processor.new(source).process }
        assert_raises(Fence::OwnershipChanged) { SimplefinEntry::Processor.new(transaction, simplefin_account: source).process }
      end
      assert_equal before, [ account, other ].map { |record| record.reload.attributes }
    end
  end

  test "a direct-only account cannot publish through another SimpleFIN source link" do
    with_source do |item, source, account|
      account.account_providers.delete_all
      account.update!(simplefin_account_id: source.id)
      other = item.simplefin_accounts.create!(name: "Other source", account_id: SecureRandom.uuid,
        currency: "USD", account_type: "checking", current_balance: 100)
      AccountProvider.create!(account: account, provider: other)

      assert_no_difference "Entry.count" do
        assert_raises(Fence::OwnershipChanged) { SimplefinEntry::Processor.new(transaction, simplefin_account: source).process }
        assert_raises(Fence::OwnershipChanged) { source.ensure_account_provider! }
      end
    end
  end

  test "a shared link requires the exact legacy item and source mapping" do
    with_source do |item, source, account|
      connection = create_provider_connection(family: item.family, provider_key: "simplefin")
      external = create_external_account(connection)
      link = account.account_providers.sole
      link.update!(external_account: external)
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin", provider_connection: connection,
        legacy_type: "SimplefinItem", legacy_id: item.id, state: "shadow")

      assert_raises(Fence::OwnershipChanged) { source.ensure_account_provider! }
      mapping = ProviderMigrationMapping.create!(family: item.family, provider_migration_control: control,
        role: "external_account", legacy_type: "SimplefinAccount", legacy_id: source.id, external_account: external)
      assert_equal link.id, source.ensure_account_provider!.id

      other = item.simplefin_accounts.create!(name: "Other source", account_id: SecureRandom.uuid,
        currency: "USD", account_type: "checking", current_balance: 100)
      mapping.update_columns(legacy_id: other.id)
      assert_raises(Fence::OwnershipChanged) { SimplefinAccount::Processor.new(source).process }
    end
  end

  test "a shared transaction adapter cannot retain a different financial account" do
    with_source do |_item, source, _account|
      adapter = Account::ProviderImportAdapter.new(accounts(:depository))
      adapter.expects(:import_transaction).never
      assert_raises(Fence::OwnershipChanged) do
        SimplefinEntry::Processor.new(transaction, simplefin_account: source, import_adapter: adapter).process
      end
    end
  end

  test "another provider can link the same account without conflicting with SimpleFIN admission" do
    with_source do |item, source, account|
      connection = create_provider_connection(family: item.family, provider_key: "up")
      external = create_external_account(connection)
      AccountProvider.create!(account: account, external_account: external)

      assert_difference "account.entries.count", 1 do
        SimplefinEntry::Processor.new(transaction, simplefin_account: source).process
      end
      assert_equal 2, account.account_providers.count
    end
  end

  test "a reparented source cannot acquire admission using its stale original item" do
    with_source do |item, source, _account|
      source.simplefin_item
      other = SimplefinItem.create!(family: item.family, name: "Other item", access_url: "https://example.com/other")
      SimplefinAccount.where(id: source.id).update_all(simplefin_item_id: other.id)
      assert_no_difference "Entry.count" do
        assert_raises(Fence::OwnershipChanged) { SimplefinEntry::Processor.new(transaction, simplefin_account: source).process }
      end
    ensure
      source&.update_columns(simplefin_item_id: item.id)
      other&.delete
    end
  end

  test "ownership loss between transactions propagates instead of becoming partial success" do
    with_source do |item, source, _account|
      source.update!(raw_transactions_payload: [ transaction, transaction.merge(id: "second") ])
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin",
        legacy_type: "SimplefinItem", legacy_id: item.id)
      Account::ProviderImportAdapter.any_instance.expects(:import_transaction).once.with do |**_attributes|
        control.update!(state: "quiescing")
        true
      end.returns(:entry)

      assert_raises(Fence::OwnershipChanged) { SimplefinAccount::Transactions::Processor.new(source).process }
    end
  end

  test "financial processing holds the item permit until the import returns" do
    with_source do |item, source, _account|
      Account::ProviderImportAdapter.any_instance.expects(:import_transaction).with do |**_attributes|
        assert_operator ApplicationRecord.connection.open_transactions, :>=, 1
        assert_equal :busy, try_drain(item)
        true
      end.returns(:entry)

      assert_equal :entry, SimplefinEntry::Processor.new(transaction, simplefin_account: source).process
      assert_equal :drained, try_drain(item)
    end
  end

  test "link repair rejects a concurrent account edit without leaking a new provider link" do
    with_source do |_item, source, account|
      account.account_providers.delete_all
      account.update!(simplefin_account_id: source.id)
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
      assert_no_difference "AccountProvider.count" do
        assert_raises(Fence::Busy) { source.ensure_account_provider! }
      end
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end
  end

  test "unlink or relink after transaction owner selection cannot publish to either account" do
    [ :unlink, :relink ].each do |change|
      with_source do |item, source, account|
        other = Account.create!(family: item.family, name: "Other publication owner", currency: "USD", balance: 0, accountable: Depository.new)
        link = account.account_providers.sole
        original = SimplefinItem::LegacyAccess.method(:with_publication)
        changed = lambda do |selected, expected_account:, &block|
          change == :unlink ? link.destroy! : link.update!(account: other)
          original.call(selected, expected_account: expected_account, &block)
        end

        assert_no_difference [ "Entry.count", "Transaction.count", "ProviderMerchant.count" ] do
          SimplefinItem::LegacyAccess.stub(:with_publication, changed) do
            assert_raises(Fence::OwnershipChanged) do
              SimplefinEntry::Processor.new(transaction.merge(payee: "Unpublished merchant"), simplefin_account: source).process
            end
          end
        end
        assert_empty account.entries
        assert_empty other.entries
        assert_equal 0, account.reload.balance
        assert_equal 0, other.reload.balance
      end
    end
  end

  test "publication rejects a changed financial currency instead of using a stale adapter context" do
    with_source do |_item, source, account|
      original = SimplefinItem::LegacyAccess.method(:with_publication)
      changed = lambda do |selected, expected_account:, &block|
        Account.where(id: account.id).update_all(currency: "EUR")
        original.call(selected, expected_account: expected_account, &block)
      end

      assert_no_difference [ "Entry.count", "Transaction.count", "ProviderMerchant.count" ] do
        SimplefinItem::LegacyAccess.stub(:with_publication, changed) do
          assert_raises(Fence::OwnershipChanged) do
            SimplefinEntry::Processor.new(transaction.merge(payee: "Unpublished merchant"), simplefin_account: source).process
          end
        end
      end
      assert_equal "EUR", account.reload.currency
      assert_equal account.id, source.reload.current_account.id
    end
  end

  test "transaction publication keeps actual unlink admission out until import completes" do
    with_source do |_item, source, account|
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      Account::ProviderImportAdapter.any_instance.expects(:import_transaction).once.with do |**_attributes|
        worker = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            Account::Unlink::LegacyAccess.with_account(Account.find(account.id)) { :entered }
          end
        rescue Fence::Busy
          :busy
        end
        begin
          assert_equal :busy, Timeout.timeout(5) { worker.value }
        ensure
          worker.kill if worker.alive?
          worker.join
        end
        true
      end.returns(:entry)

      assert_equal :entry, SimplefinEntry::Processor.new(transaction, simplefin_account: source).process
      assert_equal :entered, Account::Unlink::LegacyAccess.with_account(account) { :entered }
    end
  end

  test "a directly locked link defers publication before merchant or financial effects" do
    with_source do |_item, source, account|
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      link = account.account_providers.sole
      entered, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          AccountProvider.transaction do
            AccountProvider.lock.find(link.id)
            entered << true
            release.pop
          end
        end
      end
      Timeout.timeout(5) { entered.pop }

      assert_no_difference [ "Entry.count", "Transaction.count", "ProviderMerchant.count" ] do
        assert_raises(Fence::Busy) do
          SimplefinEntry::Processor.new(transaction.merge(payee: "Unpublished merchant"), simplefin_account: source).process
        end
      end
      assert_no_difference "AccountProvider.count" do
        assert_raises(Fence::Busy) { source.ensure_account_provider! }
      end
      assert AccountProvider.exists?(link.id)
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end
  end

  test "an admitted outer caller can rescue publication failure without committing its merchant or entry" do
    with_source do |item, source, account|
      Fence.with_item(item, operation: :publish) do
        Account.transaction do
          assert_no_difference [ "Entry.count", "Transaction.count", "ProviderMerchant.count", "DataEnrichment.count" ] do
            assert_raises(IOError) do
              SimplefinItem::LegacyAccess.with_publication(source, expected_account: account) do |fresh, financial|
                assert_equal account.id, financial.id
                entry = SimplefinEntry::Processor.new(transaction.merge(payee: "Rolled back merchant"), simplefin_account: fresh).process
                assert entry.persisted?
                assert entry.transaction.merchant_id
                raise IOError, "Simulated failure after publication"
              end
            end
          end
          source.update!(name: "Outer transaction continued")
        end
      end

      assert_empty account.entries
      assert_equal "Outer transaction continued", source.reload.name
    end
  end

  private
    def transaction
      { "id" => "current", "amount" => "-12.34", "posted" => Time.utc(2026, 9, 2, 12).to_i,
        "currency" => "USD", "description" => "Coffee" }.with_indifferent_access
    end

    def with_source
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN admission test")
        item = SimplefinItem.create!(family: family, name: "SimpleFIN", access_url: "https://example.com/access")
        source = item.simplefin_accounts.create!(name: "Checking", account_id: SecureRandom.uuid,
          currency: "USD", account_type: "checking", current_balance: 100)
        account = Account.create!(family: family, name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
        AccountProvider.create!(account: account, provider: source)
        yield item, source, account
      ensure
        if family&.persisted?
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          ProviderMigrationMapping.where(family: family).delete_all
          ProviderMigrationControl.where(family: family).delete_all
          ExternalAccount.where(family: family).delete_all
          ProviderConnection.where(family: family).delete_all
          family.accounts.reload.each(&:destroy!)
          item&.reload&.destroy!
          family.destroy!
        end
      end
    end

    def try_drain(item)
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
end
