require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class UpItem::LegacyWriterTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    SyncJob.stubs(:perform_later)
    DestroyJob.stubs(:perform_later)
  end

  test "native ownership denies every direct import processing and snapshot entry before a write" do
    with_source do |item, source, account|
      sync = item.syncs.create!
      native_owner(item)
      Provider::Up.expects(:new).never
      operations = [
        -> { UpItem::Importer.new(item).import },
        -> { UpItem::Syncer.new(item).perform_sync(sync) },
        -> { UpAccount::Processor.new(source).process },
        -> { UpAccount::Transactions::Processor.new(source).process },
        -> { UpEntry::Processor.new(transaction, up_account: source).process },
        -> { item.upsert_up_snapshot!({ items: [ snapshot ] }) },
        -> { source.upsert_up_snapshot!(snapshot) },
        -> { source.upsert_up_transactions_snapshot!([ transaction ]) },
        -> { item.up_accounts.build(account_id: "discovery").upsert_up_snapshot!(snapshot(id: "discovery")) }
      ]

      assert_no_difference [ "UpAccount.count", "Entry.count", "Merchant.count" ] do
        operations.each { |operation| assert_raises(Fence::OwnershipChanged, &operation) }
      end
      assert_nil item.reload.raw_payload
      assert_nil source.reload.raw_payload
      assert_equal BigDecimal("0"), account.reload.balance
    end
  end

  test "native ownership denies all Up lifecycle commands and direct destruction" do
    with_source do |item, source, account|
      native_owner(item)
      lifecycle = UpItem::Lifecycle.new(item)
      operations = [
        -> { lifecycle.discover_accounts },
        -> { lifecycle.update_settings(name: "Rejected", access_token: "rejected-token") },
        -> { lifecycle.link_accounts(account_ids: [ source.id ], account_type: "Depository") },
        -> { lifecycle.link_existing_account(account_id: account.id, up_account_id: source.id) },
        -> { lifecycle.complete_account_setup(account_types: { source.id => "skip" }) },
        -> { lifecycle.disconnect },
        -> { item.unlink_all! },
        -> { item.destroy_later },
        -> { item.destroy! },
        -> { source.destroy! }
      ]
      Provider::Up.expects(:new).never
      DestroyJob.expects(:perform_later).never
      assert_no_difference [ "Account.count", "AccountProvider.count", "UpItem.count", "UpAccount.count" ] do
        operations.each { |operation| assert_raises(Fence::OwnershipChanged, &operation) }
      end
      assert_equal "Legacy Up", item.reload.name
      assert_not item.scheduled_for_deletion?
      assert_not source.reload.ignored?
    end
  end

  test "a direct importer reloads credentials and holds the drain fence across HTTP and storage" do
    with_source do |item, source, _account|
      stale = UpItem.find(item.id)
      importer = UpItem::Importer.new(stale)
      item.update!(access_token: "rotated-up-token")
      provider = mock("fresh Up client")
      Provider::Up.expects(:new).with("rotated-up-token").returns(provider)
      provider.expects(:get_accounts).returns([ snapshot ])
      provider.expects(:get_account_transactions).with do |account_id:, since:|
        assert_equal "acc_1", account_id
        assert since
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal :busy, drain_in_another_session(item)
      end.returns([ transaction ])

      assert importer.import[:success]
      assert_equal BigDecimal("25.50"), source.reload.current_balance
      assert_equal [ "tx_1" ], source.raw_transactions_payload.map { |row| row.fetch("id") }
      assert_equal :drained, drain_in_another_session(item)
    end
  end

  test "account processing reloads both the snapshot and financial binding" do
    with_source do |_item, source, original_account|
      stale = UpAccount.find(source.id)
      assert_equal original_account, stale.current_account
      replacement = create_account(source.up_item.family)
      source.account_provider.update!(account: replacement)
      source.update!(current_balance: 75, raw_transactions_payload: [ transaction ])
      stale.current_balance = 999

      result = UpAccount::Processor.new(stale).process

      assert result[:success]
      assert_equal BigDecimal("75"), replacement.reload.balance
      assert_equal BigDecimal("0"), original_account.reload.balance
      assert_empty original_account.entries
      assert_equal BigDecimal("12.50"), replacement.entries.find_by!(external_id: "up_tx_1").amount
    end
  end

  test "reusing an entry processor cannot retain its old financial adapter" do
    with_source do |item, source, original_account|
      processor = UpEntry::Processor.new(transaction, up_account: source)
      first = processor.process
      replacement = create_account(item.family)
      source.account_provider.update!(account: replacement)

      second = processor.process

      assert_equal original_account.id, first.account_id
      assert_equal replacement.id, second.account_id
      assert_not_equal first.id, second.id
    end
  end

  test "stale foreign and deleted source arguments cannot publish" do
    with_source do |item, source, account|
      stale = UpAccount.find(source.id)
      other = create_item(families(:dylan_family))
      source.update!(up_item: other)
      assert_raises(Fence::OwnershipChanged) { UpAccount::Processor.new(stale).process }
      source.update!(up_item: item)
      foreign_account = create_account(other.family)
      source.account_provider.update!(account: foreign_account)
      assert_raises(Fence::OwnershipChanged) { UpEntry::Processor.new(transaction, up_account: stale).process }
      source.account_provider.update!(account: account)
      source.destroy!
      assert_raises(Fence::OwnershipChanged) { UpAccount::Transactions::Processor.new(stale).process }
      assert_empty account.entries
      assert_empty foreign_account.entries
    end
  end

  test "discovery and setup preserve skipped accounts and loan balance semantics" do
    with_source do |item, _source, _account|
      stale = UpItem.find(item.id)
      item.update!(access_token: "discovery-token")
      provider = mock("discovery client")
      Provider::Up.expects(:new).with("discovery-token").returns(provider)
      loan = snapshot(id: "loan").merge(accountType: "HOME_LOAN", balance: { value: "-125.75", currencyCode: "AUD" })
      provider.expects(:get_accounts).returns([ loan, snapshot(id: "skip") ])
      lifecycle = UpItem::Lifecycle.new(stale)
      lifecycle.discover_accounts
      loan_source = item.up_accounts.find_by!(account_id: "loan")
      skipped_source = item.up_accounts.find_by!(account_id: "skip")
      result = lifecycle.complete_account_setup(account_types: { loan_source.id => "Loan", skipped_source.id => "skip" })

      assert_equal 1, result[:created_accounts].length
      assert_equal 1, result[:skipped_count]
      assert_equal BigDecimal("125.75"), result[:created_accounts].first.balance
      assert skipped_source.reload.ignored?
      assert_nil skipped_source.account_provider
      assert_equal [], lifecycle.link_accounts(account_ids: [ loan_source.id ], account_type: "Loan")
    end
  end

  test "linking an existing account rechecks the financial family's ownership" do
    with_source do |item, source, _account|
      foreign = create_account(families(:dylan_family))
      lifecycle = UpItem::Lifecycle.new(item)
      assert_raises(ActiveRecord::RecordNotFound) do
        lifecycle.link_existing_account(account_id: foreign.id, up_account_id: source.id)
      end
      assert_empty foreign.account_providers
    end
  end

  test "settings update and direct discovery reload their caller's stale state" do
    with_source do |item, _source, _account|
      stale = UpItem.find(item.id)
      item.update!(access_token: "current-token")
      changed = UpItem::Lifecycle.new(stale).update_settings(name: "Renamed")
      assert_equal "Renamed", changed.name
      assert_equal "current-token", changed.access_token

      discovered = stale.up_accounts.build(account_id: "direct-discovery", ignored: true)
      assert discovered.upsert_up_snapshot!(snapshot(id: "direct-discovery"))
      assert discovered.persisted?
      assert_not discovered.reload.ignored?, "unpersisted caller attributes are not copied into a new source"
      assert_equal item.id, discovered.up_item_id
      assert_equal BigDecimal("25.50"), discovered.current_balance
    end
  end

  test "disconnect unlinks and schedules deletion under one permit" do
    with_source do |item, source, account|
      DestroyJob.expects(:perform_later).with do |current|
        assert current.scheduled_for_deletion?
        assert_equal :busy, drain_in_another_session(item)
        assert_empty account.account_providers
      end
      result = UpItem::Lifecycle.new(item).disconnect
      assert_equal source.id, result.first[:provider_account_id]
      assert_nil result.first[:error]
      assert item.reload.scheduled_for_deletion?
      assert Account.exists?(account.id)
    end
  end

  test "a family cascade cannot start an unfenced transaction around source destruction" do
    with_source do |item, source, account|
      assert_raises(ArgumentError) do
        UpItem.transaction { item.destroy! }
      end
      assert UpItem.exists?(item.id)
      assert UpAccount.exists?(source.id)
      assert account.account_providers.exists?
    end
  end

  private
    def with_source
      @owned_items = []
      @owned_accounts = []
      with_provider_encryption do
        item = create_item(families(:empty))
        source = item.up_accounts.create!(name: "Spending", account_id: "acc_1", currency: "AUD", current_balance: 10)
        account = create_account(item.family)
        AccountProvider.create!(account: account, provider: source)
        yield item, source, account
      ensure
        account_ids = (@owned_accounts.map(&:id) + @owned_items.flat_map { |owned| owned.accounts.pluck(:id) }).uniq
        Account.where(id: account_ids).find_each(&:destroy!)
        ProviderMigrationControl.where(legacy_type: "UpItem", legacy_id: @owned_items.map(&:id)).destroy_all
        @owned_items.each { |owned| UpItem.find_by(id: owned.id)&.destroy! }
        clear_enqueued_jobs
      end
    end

    def create_item(family)
      UpItem.create!(family: family, name: "Legacy Up", access_token: "up-token").tap { |item| @owned_items << item }
    end

    def create_account(family)
      Account.create!(family: family, name: "Spending", accountable: Depository.new(subtype: "checking"),
        balance: 0, currency: "AUD").tap { |account| @owned_accounts << account }
    end

    def native_owner(item)
      ProviderMigrationControl.create!(family: item.family, provider_key: "up", legacy_type: "UpItem", legacy_id: item.id, state: "active")
    end

    def snapshot(id: "acc_1")
      { id: id, displayName: "Spending", accountType: "TRANSACTIONAL", ownershipType: "INDIVIDUAL",
        balance: { value: "25.50", currencyCode: "AUD" } }
    end

    def transaction
      { id: "tx_1", account_id: "acc_1", status: "SETTLED", description: "Coffee",
        amount: { value: "-12.50", currencyCode: "AUD" }, settledAt: "2026-09-01T09:00:00+10:00" }
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
