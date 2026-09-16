require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class MercuryItem::LegacyAccessTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false
  Access = MercuryItem::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    Sentry.stubs(:capture_exception)
    SyncJob.stubs(:perform_later)
    Account.any_instance.stubs(:sync_later)
  end

  test "quiescing and native ownership refuse every direct writer before credentials or effects" do
    with_source do |item, source, account|
      sync = item.syncs.create!
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "mercury", legacy_type: "MercuryItem", legacy_id: item.id)
      Provider::Mercury.expects(:new).never
      operations = [
        -> { MercuryItem::Importer.new(item).import },
        -> { MercuryItem::Syncer.new(item).perform_sync(sync) },
        -> { item.import_latest_mercury_data },
        -> { item.process_accounts },
        -> { item.schedule_account_syncs },
        -> { MercuryAccount::Processor.new(source).process },
        -> { MercuryAccount::Transactions::Processor.new(source).process },
        -> { MercuryEntry::Processor.new(transaction, mercury_account: source).process },
        -> { item.upsert_mercury_snapshot!(accounts: [ snapshot ]) },
        -> { source.upsert_mercury_snapshot!(snapshot) },
        -> { source.upsert_mercury_transactions_snapshot!([ transaction ]) },
        -> { item.mercury_accounts.build(account_id: "new").upsert_mercury_snapshot!(snapshot(id: "new")) }
      ]
      %w[quiescing active retired rollback_pending].each do |state|
        control.update!(state: state)
        assert_no_difference [ "MercuryAccount.count", "Entry.count", "Merchant.count", "Sync.count" ] do
          operations.each { |operation| assert_raises(Fence::OwnershipChanged, &operation) }
        end
      end
      assert_nil item.reload.raw_payload
      assert_nil source.reload.raw_payload
      assert_equal BigDecimal("10"), account.reload.balance
    end
  end

  test "direct import reloads credentials and retains the drain permit across HTTP without a row transaction" do
    with_source do |item, source, _account|
      importer = MercuryItem::Importer.new(MercuryItem.find(item.id))
      item.update!(token: "fresh-token", base_url: "https://example.test/mercury")
      provider = mock("fresh Mercury client")
      Provider::Mercury.expects(:new).with("fresh-token", base_url: "https://example.test/mercury").returns(provider)
      provider.expects(:get_accounts).with do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal :busy, drain_in_another_session(item)
      end.returns(accounts: [ snapshot ])
      provider.expects(:get_account_transactions).with do |id, start_date:|
        assert_equal "account-1", id
        assert start_date
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal :busy, drain_in_another_session(item)
      end.returns(transactions: [ transaction ])

      assert importer.import[:success]

      assert_equal BigDecimal("55.25"), source.reload.current_balance
      assert_equal [ "transaction-1" ], source.raw_transactions_payload.map { |row| row.fetch("id") }
      assert_equal :drained, drain_in_another_session(item)
    end
  end

  test "direct Syncer validates original Sync and retains admission through scheduling" do
    with_source do |item, source, account|
      sync = item.syncs.create!
      provider = mock("Mercury client")
      Provider::Mercury.stubs(:new).returns(provider)
      provider.expects(:get_accounts).returns(accounts: [ snapshot ])
      provider.expects(:get_account_transactions).returns(transactions: [ transaction ])
      Account.any_instance.expects(:sync_later).with do |parent_sync:, window_start_date:, window_end_date:|
        assert_equal sync.id, parent_sync.id
        assert_equal :busy, drain_in_another_session(item)
        assert_equal 0, ApplicationRecord.connection.open_transactions
      end

      MercuryItem::Syncer.new(item).perform_sync(sync)

      assert_equal BigDecimal("55.25"), account.reload.balance
      assert_equal 1, account.entries.where(source: "mercury").count
      assert_not item.reload.pending_account_setup?
      sync.update!(cancel_requested_at: Time.current)
      Provider::Mercury.expects(:new).never
      assert_raises(Fence::OwnershipChanged) { MercuryItem::Syncer.new(item).perform_sync(sync) }
    end
  end

  test "fresh snapshot and link replace cached receivers without publishing to their stale financial owner" do
    with_source do |item, source, original|
      stale = MercuryAccount.find(source.id)
      assert_equal original, stale.current_account
      other = create_account(item.family, "New linked account")
      source.account_provider.update!(account: other)
      source.update!(current_balance: 123, raw_transactions_payload: [ transaction ])
      stale.current_balance = 999

      assert MercuryAccount::Processor.new(stale).process[:success]

      assert_equal BigDecimal("123"), other.reload.balance
      assert_equal BigDecimal("12.50"), other.entries.sole.amount
      assert_equal BigDecimal("10"), original.reload.balance
      assert_empty original.entries
    end
  end

  test "reusing an Entry processor rebuilds its financial import adapter" do
    with_source do |item, source, account|
      processor = MercuryEntry::Processor.new(transaction, mercury_account: source)
      first = processor.process
      other = create_account(item.family, "Another account")
      source.account_provider.update!(account: other)

      second = processor.process

      assert_equal account.id, first.account_id
      assert_equal other.id, second.account_id
      assert_not_equal first.id, second.id
    end
  end

  test "relink and financial currency changes between selection and publication refuse before merchant or entry writes" do
    %i[link currency].each do |change|
      with_source do |item, source, account|
        other = create_account(item.family, "Another account")
        original = Access.method(:with_publication)
        changed = lambda do |selected, expected_account:, &block|
          change == :link ? source.account_provider.update!(account: other) : account.update!(currency: "EUR")
          original.call(selected, expected_account: expected_account, &block)
        end
        assert_no_difference [ "Entry.count", "Merchant.count" ] do
          Access.stub(:with_publication, changed) do
            assert_raises(Fence::OwnershipChanged) { MercuryEntry::Processor.new(transaction, mercury_account: source).process }
          end
        end
        assert_equal BigDecimal("10"), account.reload.balance
        assert_equal BigDecimal("10"), other.reload.balance
      end
    end
  end

  test "foreign and deleted source arguments cannot broaden an admitted item" do
    with_source do |item, source, account|
      stale = MercuryAccount.find(source.id)
      stale.mercury_item
      other = MercuryItem.create!(family: item.family, name: "Other Mercury", token: "other")
      source.update!(mercury_item: other)
      assert_raises(Fence::OwnershipChanged) { MercuryAccount::Processor.new(stale).process }
      source.update!(mercury_item: item)
      source.destroy!
      assert_raises(Fence::OwnershipChanged) { MercuryAccount::Transactions::Processor.new(stale).process }
      assert_empty account.entries
    end
  end

  test "a raw transaction or account snapshot for another remote account is refused" do
    with_source do |_item, source, account|
      assert_no_difference [ "Entry.count", "Merchant.count" ] do
        assert_raises(Fence::OwnershipChanged) do
          MercuryEntry::Processor.new(transaction.merge("accountId" => "another"), mercury_account: source).process
        end
        assert_raises(Fence::OwnershipChanged) { source.upsert_mercury_snapshot!(snapshot(id: "another")) }
      end
      assert_equal "account-1", source.reload.account_id
      assert_equal BigDecimal("10"), account.reload.balance
    end
  end

  test "account row contention raises Busy before publication and never downgrades to ordinary processing failure" do
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
      assert_raises(Fence::Busy) { MercuryAccount::Processor.new(source).process }
      assert_equal BigDecimal("10"), account.reload.balance
      assert_empty account.entries
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end
  end

  test "after-update balance failure rolls back SQL inside the local publication savepoint" do
    with_source do |_item, source, account|
      observed = []
      callback = lambda do |changed|
        if changed.id == account.id && changed.balance == BigDecimal("25")
          observed << Account.where(id: account.id).pick(:balance)
          raise IOError, "Simulated local callback failure"
        end
      end
      Account.set_callback(:update, :after, callback)
      begin
        assert_raises(IOError) { MercuryAccount::Processor.new(source).process }
      ensure
        Account.skip_callback(:update, :after, callback)
      end
      assert_equal [ BigDecimal("25") ], observed
      assert_equal BigDecimal("10"), account.reload.balance
      assert_empty account.entries
    end
  end

  test "a failed delegated transaction callback rolls back its merchant and financial row before the batch reports failure" do
    with_source do |_item, source, account|
      source.update!(raw_transactions_payload: [ transaction ])
      callback = ->(_transaction) { raise IOError, "Simulated transaction callback failure" }
      Transaction.set_callback(:create, :after, callback)
      begin
        assert_no_difference [ "Entry.count", "Transaction.count", "Merchant.count" ] do
          result = MercuryAccount::Transactions::Processor.new(source).process
          assert_equal false, result[:success]
          assert_equal 1, result[:failed]
        end
      ensure
        Transaction.skip_callback(:create, :after, callback)
      end
      assert_empty account.entries
      assert MercuryAccount::Transactions::Processor.new(source).process[:success]
      assert_equal 1, account.entries.count
    end
  end

  test "unadmitted outer transactions and scheduled source deletion refuse before transport" do
    with_source do |item, source, _account|
      Provider::Mercury.expects(:new).never
      ApplicationRecord.transaction do
        assert_raises(ArgumentError) { MercuryItem::Importer.new(item).import }
      end
      Access.with_item(item) do
        ApplicationRecord.transaction do
          assert_raises(Fence::InvalidSource) { MercuryItem::Importer.new(item).import }
        end
      end
      item.update!(scheduled_for_deletion: true)
      assert_raises(Fence::OwnershipChanged) { MercuryItem::Importer.new(item).import }
      assert_raises(Fence::OwnershipChanged) { MercuryAccount::Processor.new(source).process }
      assert_raises(Fence::OwnershipChanged) { item.upsert_mercury_snapshot!({}) }
    end
  end

  private
    def with_source
      with_provider_encryption do
        merchant_name = @mercury_merchant_name = "Mercury admission #{SecureRandom.uuid}"
        family = Family.create!(name: "Mercury admission")
        item = MercuryItem.create!(family: family, name: "Mercury", token: "original-token")
        source = item.mercury_accounts.create!(name: "Checking", account_id: "account-1", currency: "USD", current_balance: 25)
        account = create_account(family, "Checking")
        AccountProvider.create!(account: account, provider: source)
        yield item, source, account
      ensure
        if family
          ProviderMigrationControl.where(family: family).delete_all
          Sync.where(syncable_type: "MercuryItem", syncable_id: family.mercury_items.select(:id)).delete_all
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          family.accounts.each(&:destroy!)
          family.mercury_items.destroy_all
          family.destroy!
        end
        ProviderMerchant.where(source: "mercury", name: merchant_name).delete_all if merchant_name
        @mercury_merchant_name = nil
      end
    end

    def create_account(family, name)
      family.accounts.create!(name: name, balance: 10, currency: "USD", accountable: Depository.new)
    end

    def snapshot(id: "account-1")
      { id: id, name: "Checking", currentBalance: "55.25", status: "active", type: "checking" }
    end

    def transaction
      { "id" => "transaction-1", "amount" => "-12.50", "status" => "sent", "counterpartyName" => @mercury_merchant_name,
        "createdAt" => "2026-09-01T12:00:00Z", "postedAt" => "2026-09-02T12:00:00Z" }
    end

    def drain_in_another_session(item)
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
