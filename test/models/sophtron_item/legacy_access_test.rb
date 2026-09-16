require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class SophtronItem::LegacyAccessTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  test "every public ingestion and scheduling boundary rejects quiescing and native owners before normalization" do
    with_source do |item, source, account|
      sync = item.syncs.create!
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "sophtron",
        legacy_type: "SophtronItem", legacy_id: item.id, state: "quiescing")
      payload = mock("must not normalize")
      payload.expects(:with_indifferent_access).never
      SophtronItem.any_instance.expects(:sophtron_provider).never
      before_item, before_source, before_account = [ item, source, account ].map { |record| record.reload.attributes }

      operations = [
        -> { SophtronItem::Importer.new(item).import },
        -> { SophtronItem::Importer.new(item).import_transactions_after_refresh(source) },
        -> { SophtronAccount::Processor.new(source).process },
        -> { SophtronAccount::Transactions::Processor.new(source).process },
        -> { SophtronEntry::Processor.new(payload, sophtron_account: source).process },
        -> { item.import_latest_sophtron_data },
        -> { item.process_accounts },
        -> { item.upsert_sophtron_snapshot!(payload) },
        -> { item.upsert_job_snapshot!(payload) },
        -> { source.upsert_sophtron_snapshot!(payload) },
        -> { source.upsert_sophtron_transactions_snapshot!(payload) },
        -> { item.sophtron_accounts.build.upsert_sophtron_snapshot!(payload) },
        -> { item.schedule_account_syncs },
        -> { item.start_initial_load_later },
        -> { SophtronItem::Syncer.new(item).perform_sync(sync) }
      ]
      %w[quiescing active retired].each do |state|
        control.update!(state: state)
        assert_no_enqueued_jobs do
          assert_no_difference [ "Entry.count", "Merchant.count", "SophtronAccount.count", "Sync.count" ] do
            operations.each { |operation| assert_raises(Fence::OwnershipChanged, &operation) }
          end
        end
        assert_equal before_item, item.reload.attributes
        assert_equal before_source, source.reload.attributes
        assert_equal before_account, account.reload.attributes
      end
    end
  end

  test "direct import builds a fresh client and prevents exclusive drain throughout HTTP" do
    with_source(linked: false) do |item, _source, _account|
      SophtronItem.find(item.id).update!(user_id: "fresh-user")
      provider = mock("fresh client")
      Provider::Sophtron.expects(:new).with("fresh-user", item.access_key, base_url: item.effective_base_url).returns(provider)
      provider.expects(:get_accounts).with do |institution|
        assert_equal "institution", institution
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal :busy, try_drain(item)
        true
      end.returns({ accounts: [] })

      assert SophtronItem::Importer.new(item).import[:success]
      assert_equal :drained, try_drain(item)
      assert_equal "developer-user", item.user_id
    end
  end

  test "foreign failed cancelled and completed ordinary syncs reject before clients or status changes" do
    with_source do |item, source, _account|
      foreign = item.family.syncs.create!
      contexts = [ foreign, item.syncs.create!(status: "failed"),
        item.syncs.create!(cancel_requested_at: Time.current), item.syncs.create!(status: "completed") ]
      SophtronItem.any_instance.expects(:sophtron_provider).never
      contexts.each do |sync|
        before = sync.reload.attributes
        assert_raises(Fence::OwnershipChanged) { SophtronItem::Importer.new(item, sync: sync).import }
        assert_raises(Fence::OwnershipChanged) { SophtronAccount::Processor.new(source, sync: sync).process }
        assert_raises(Fence::OwnershipChanged) { SophtronItem::Syncer.new(item).perform_sync(sync) }
        assert_raises(Fence::OwnershipChanged) { item.schedule_account_syncs(parent_sync: sync) }
        assert_equal before, sync.reload.attributes
      end
    ensure
      foreign&.destroy!
    end
  end

  test "completed delayed refresh can import and schedule its exact account but cancelled completion cannot" do
    with_source do |item, source, account|
      sync = item.syncs.create!(status: "completed", window_start_date: Date.new(2026, 9, 1))
      provider = mock("refresh client")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      provider.expects(:get_account_transactions).with(source.account_id, start_date: sync.window_start_date)
        .returns({ transactions: [ transaction ] })
      assert SophtronItem::Importer.new(item, sync: sync).import_transactions_after_refresh(source)[:success]
      assert_equal [ "transaction" ], source.reload.raw_transactions_payload.pluck("id")
      assert_enqueued_with(job: SyncJob) do
        item.schedule_account_syncs(sophtron_accounts_scope: [ source ], parent_sync: sync,
          window_start_date: sync.window_start_date, allow_completed: true)
      end
      assert_equal account.id, sync.children.sole.syncable_id
      sync.update_columns(cancel_requested_at: Time.current)
      assert_no_enqueued_jobs do
        assert_raises(Fence::OwnershipChanged) { SophtronItem::Importer.new(item, sync: sync).import_transactions_after_refresh(source) }
      end
    end
  end

  test "cancellation during account discovery prevents payload publication and is not a partial result" do
    with_source do |item, _source, _account|
      sync = item.syncs.create!
      provider = mock("discovery client")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      provider.expects(:get_accounts).with do |_institution|
        sync.update_columns(cancel_requested_at: Time.current)
        true
      end.returns({ accounts: [ { account_id: "new", account_name: "New", balance: "1" } ] })
      before = item.reload.attributes
      assert_no_difference "SophtronAccount.count" do
        assert_raises(Fence::OwnershipChanged) { SophtronItem::Importer.new(item, sync: sync).import }
      end
      assert_equal before, item.reload.attributes
    end
  end

  test "cancellation during a failed transaction request does not publish authentication errors" do
    with_source do |item, source, _account|
      sync = item.syncs.create!(status: "completed")
      provider = mock("cancelled client")
      SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
      provider.expects(:get_account_transactions).with do |_id, **_options|
        sync.update_columns(cancel_requested_at: Time.current)
        true
      end.raises(Provider::Sophtron::Error.new("unauthorized", :unauthorized))
      before = [ item, source ].map { |record| record.reload.attributes }
      assert_raises(Fence::OwnershipChanged) do
        SophtronItem::Importer.new(item, sync: sync).import_transactions_after_refresh(source)
      end
      assert_equal before, [ item, source ].map { |record| record.reload.attributes }
    end
  end

  test "foreign selected account is rejected before constructing a delayed import client" do
    with_source do |item, _source, _account|
      with_source do |_other, foreign_source, _foreign_account|
        SophtronItem.any_instance.expects(:sophtron_provider).never
        assert_raises(Fence::OwnershipChanged) do
          SophtronItem::Importer.new(item).import_transactions_after_refresh(foreign_source)
        end
        assert_no_enqueued_jobs do
          assert_raises(Fence::OwnershipChanged) { item.schedule_account_syncs(sophtron_accounts_scope: [ foreign_source ]) }
        end
      end
    end
  end

  test "stale reparented account is rejected by snapshot and processor boundaries" do
    with_source do |item, source, account|
      with_source(linked: false) do |other, _other_source, _other_account|
        source.sophtron_item = item
        SophtronAccount.find(source.id).update_columns(sophtron_item_id: other.id)
        before = account.reload.attributes
        assert_raises(Fence::OwnershipChanged) { source.upsert_sophtron_transactions_snapshot!([ transaction ]) }
        assert_raises(Fence::OwnershipChanged) { SophtronAccount::Processor.new(source).process }
        assert_equal before, account.reload.attributes
      ensure
        SophtronAccount.where(id: source.id).update_all(sophtron_item_id: item.id)
      end
    end
  end

  test "cross-family links reject normalization and scheduling" do
    with_source do |item, source, _account|
      foreign = Account.create!(family: families(:empty), name: "Foreign", currency: "USD",
        balance: 0, accountable: Depository.new)
      source.account_provider.update!(account: foreign)
      payload = mock("unread transaction")
      payload.expects(:with_indifferent_access).never
      assert_raises(Fence::OwnershipChanged) { SophtronEntry::Processor.new(payload, sophtron_account: source).process }
      assert_no_enqueued_jobs do
        assert_raises(Fence::OwnershipChanged) { item.schedule_account_syncs(sophtron_accounts_scope: [ source ]) }
      end
    ensure
      foreign&.destroy!
    end
  end

  test "processors refresh balances and cached transaction payloads before normalization" do
    with_source do |_item, source, account|
      source.current_account # Prime an association on the stale argument.
      SophtronAccount.find(source.id).update!(balance: 456, raw_transactions_payload: [ transaction ])
      result = SophtronAccount::Processor.new(source).process
      assert result[:success]
      assert_equal 456, account.reload.balance
      assert_equal BigDecimal("12.34"), account.entries.find_by!(external_id: "sophtron_transaction").amount
      assert_equal 100, source.balance
    end
  end

  test "direct entry processing refreshes a changed same-family financial link" do
    with_source do |item, source, original|
      replacement = Account.create!(family: item.family, name: "Replacement", currency: "USD",
        balance: 0, accountable: Depository.new)
      source.current_account
      source.account_provider.update!(account: replacement)
      result = SophtronEntry::Processor.new(transaction, sophtron_account: source).process
      assert_equal replacement.id, result.account_id
      assert_not original.entries.exists?(external_id: "sophtron_transaction")
    ensure
      replacement&.destroy!
    end
  end

  test "new snapshots inherit fresh item metadata and persisted snapshots cannot change remote identity" do
    with_source(linked: false) do |item, source, _account|
      SophtronItem.find(item.id).update!(institution_name: "Current bank", manual_sync: true)
      new_source = item.sophtron_accounts.build
      new_source.upsert_sophtron_snapshot!(account_id: "new", account_name: "New", balance: "5", currency: "USD")
      assert new_source.persisted?
      assert new_source.manual_sync?
      assert_equal "Current bank", new_source.institution_metadata.fetch("name")
      before = source.reload.attributes
      assert_raises(Fence::OwnershipChanged) do
        source.upsert_sophtron_snapshot!(account_id: "another", account_name: "Other", balance: "99")
      end
      assert_equal before, source.reload.attributes
    end
  end

  test "loaded scheduling scope keeps selected ids and rejects changed predicates" do
    with_source do |item, source, account|
      selected = item.automatic_sync_sophtron_accounts.order(:id).limit(1).load
      assert_equal [ source.id ], selected.map(&:id)
      sync = item.syncs.create!
      window = Date.new(2026, 9, 2)..Date.new(2026, 9, 4)
      item.schedule_account_syncs(sophtron_accounts_scope: selected, parent_sync: sync,
        window_start_date: window.begin, window_end_date: window.end)
      child = sync.children.sole
      assert_equal account.id, child.syncable_id
      assert_equal window.begin, child.window_start_date
      assert_equal window.end, child.window_end_date
      source.update!(manual_sync: true)
      assert_no_enqueued_jobs do
        assert_raises(Fence::OwnershipChanged) { item.schedule_account_syncs(sophtron_accounts_scope: selected) }
      end
    end
  end

  test "ownership loss between transactions is raised instead of collected as an individual failure" do
    with_source do |item, source, _account|
      source.update!(raw_transactions_payload: [ transaction, transaction.merge(id: "second") ])
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "sophtron",
        legacy_type: "SophtronItem", legacy_id: item.id, state: "legacy")
      Account::ProviderImportAdapter.any_instance.expects(:import_transaction).once.with do |**_attributes|
        control.update!(state: "quiescing")
        true
      end.returns(:entry)
      assert_raises(Fence::OwnershipChanged) { item.process_accounts }
    end
  end

  private
    def transaction
      { id: "transaction", amount: "-12.34", date: "2026-09-02", currency: "USD", merchant: "Coffee" }
    end

    def with_source(linked: true)
      with_provider_encryption do
        existing_merchants = ProviderMerchant.where(source: "sophtron").pluck(:id)
        item = SophtronItem.create!(family: families(:dylan_family), name: "Public boundary",
          user_id: "developer-user", access_key: Base64.strict_encode64("test-key"),
          customer_id: "customer", user_institution_id: "institution")
        source = item.sophtron_accounts.create!(account_id: SecureRandom.uuid, name: "Checking",
          currency: "USD", balance: 100, raw_transactions_payload: nil)
        if linked
          financial = Account.create!(family: item.family, name: "Sophtron boundary account", currency: "USD",
            balance: 0, accountable: Depository.new)
          AccountProvider.create!(account: financial, provider: source)
        end
        yield item, source, financial
      ensure
        ProviderMigrationControl.where(legacy_type: "SophtronItem", legacy_id: item.id).destroy_all if item&.persisted?
        financial&.destroy!
        ProviderMerchant.where(source: "sophtron").where.not(id: existing_merchants).destroy_all if existing_merchants
        if item&.persisted?
          item.reload.destroy!
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
