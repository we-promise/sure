require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class AkahuItem::SyncerAdmissionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false
  Access = AkahuItem::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    Sentry.stubs(:capture_exception)
    Account.any_instance.stubs(:sync_later)
    clear_enqueued_jobs
  end
  teardown { clear_enqueued_jobs }

  test "nonlegacy ownership refuses direct sync before transport progress stats or item flags" do
    with_source do |item, _source, account, sync|
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "akahu", legacy_type: "AkahuItem", legacy_id: item.id)
      before = [ item.reload.attributes, account.reload.attributes, sync.reload.attributes ]
      Provider::Akahu.expects(:new).never
      AkahuItem.any_instance.expects(:process_accounts).never
      AkahuItem.any_instance.expects(:schedule_account_syncs).never

      %w[quiescing active retired rollback_pending].each do |state|
        control.update!(state: state)
        assert_raises(Fence::OwnershipChanged) { AkahuItem::Syncer.new(item).perform_sync(sync) }
        assert_equal before, [ item.reload.attributes, account.reload.attributes, sync.reload.attributes ]
        assert_empty account.entries
      end
    end
  end

  test "foreign cancelled and failed original Syncs refuse before progress or transport" do
    %i[foreign cancelled failed ancestor].each do |state|
      with_source do |item, _source, _account, sync|
        case state
        when :foreign
          other = item.family.akahu_items.create!(name: "Other Akahu", app_token: "other-app", user_token: "other-user")
          sync.update!(syncable: other)
        when :cancelled then sync.update!(cancel_requested_at: Time.current)
        when :failed then sync.update!(status: "failed", failed_at: Time.current)
        when :ancestor
          parent = item.family.syncs.create!(status: "pending", cancel_requested_at: Time.current)
          sync.update!(parent: parent)
        end
        before = [ item.reload.attributes, sync.reload.attributes ]
        Provider::Akahu.expects(:new).never

        assert_raises(Fence::OwnershipChanged) { AkahuItem::Syncer.new(item).perform_sync(sync) }

        assert_equal before, [ item.reload.attributes, sync.reload.attributes ]
      end
    end
  end

  test "a missing original Sync refuses before import or item mutation" do
    with_source do |item, _source, _account, sync|
      before = [ item.reload.attributes, sync.reload.attributes ]
      AkahuItem.any_instance.expects(:import_latest_akahu_data).never

      assert_raises(Fence::InvalidSource) { AkahuItem::Syncer.new(item).perform_sync(nil) }

      assert_equal before, [ item.reload.attributes, sync.reload.attributes ]
    end
  end

  test "real import uses fresh credentials without an HTTP transaction and retains the permit through scheduling" do
    with_source do |item, source, account, sync|
      syncer = AkahuItem::Syncer.new(AkahuItem.find(item.id))
      item.update!(app_token: "replacement-app", user_token: "replacement-user")
      client = mock("admitted Akahu transport")
      Provider::Akahu.expects(:new).with(app_token: "replacement-app", user_token: "replacement-user").returns(client)
      client.expects(:get_accounts).with { assert_transport_and_permit(item) }.returns([ account_snapshot ])
      client.expects(:get_pending_transactions).with { assert_transport_and_permit(item) }.returns([])
      client.expects(:get_account_transactions).with do |account_id:, start_date:|
        assert_equal source.account_id, account_id
        assert_nil start_date
        assert_transport_and_permit(item)
      end.returns([ transaction ])
      Account.any_instance.expects(:sync_later).with do |parent_sync:, window_start_date:, window_end_date:|
        assert_equal sync.id, parent_sync.id
        assert_equal sync.window_start_date, window_start_date
        assert_equal sync.window_end_date, window_end_date
        assert_equal :busy, drain_in_another_session(item)
        true
      end.once

      syncer.perform_sync(sync)

      assert_equal BigDecimal("55.25"), account.reload.balance
      assert_equal [ "akahu_posted-1" ], account.entries.where(source: "akahu").pluck(:external_id)
      assert_equal [ "posted-1" ], source.reload.raw_transactions_payload.map { |row| row.fetch("_id") }
      refute item.reload.pending_account_setup?
      assert_equal 0, sync.reload.sync_stats.fetch("total_errors")
      assert_equal 1, sync.sync_stats.fetch("linked_accounts")
      assert_equal :drained, drain_in_another_session(item)
    end
  end

  test "pending inventory receipt is forwarded unchanged inside the original uninterrupted permit" do
    with_source do |item, source, _account, sync|
      receipt = Object.new.freeze
      permit = nil
      AkahuItem.any_instance.expects(:import_latest_akahu_data).with do
        permit = ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        assert permit
        true
      end.returns(success: true, pending_inventories: { source.id => receipt }.freeze)
      AkahuItem.any_instance.expects(:process_accounts).with do |pending_inventories:|
        assert_same receipt, pending_inventories.fetch(source.id)
        assert_same permit, ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        assert_equal :busy, drain_in_another_session(item)
        true
      end.returns([])
      AkahuItem.any_instance.expects(:schedule_account_syncs).with do |parent_sync:, **_window|
        assert_equal sync.id, parent_sync.id
        assert_same permit, ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        true
      end.returns([])
      Provider::Akahu.expects(:new).never

      AkahuItem::Syncer.new(item).perform_sync(sync)

      assert_equal 0, sync.reload.sync_stats.fetch("total_errors")
    end
  end

  test "credential replacement during import rejects subsequent progress without health or setup mutation" do
    %i[app_token user_token].each do |attribute|
      with_source do |item, _source, account, sync|
        before_sync = nil
        AkahuItem.any_instance.expects(:import_latest_akahu_data).with do
          before_sync = Sync.find(sync.id).attributes
          AkahuItem.where(id: item.id).update_all(attribute => "changed-after-admission")
          true
        end.returns(success: true)
        AkahuItem.any_instance.expects(:process_accounts).never
        AkahuItem.any_instance.expects(:schedule_account_syncs).never
        Provider::Akahu.expects(:new).never

        assert_raises(Fence::OwnershipChanged) { AkahuItem::Syncer.new(item).perform_sync(sync) }

        assert_equal before_sync, sync.reload.attributes
        assert_equal "changed-after-admission", item.reload.public_send(attribute)
        assert item.pending_account_setup?
        assert_equal BigDecimal("10"), account.reload.balance
      end
    end
  end

  test "cancellation during import refuses subsequent progress and does not report success" do
    with_source do |item, _source, _account, sync|
      before_sync = nil
      AkahuItem.any_instance.expects(:import_latest_akahu_data).with do
        sync.update!(cancel_requested_at: Time.current)
        before_sync = sync.reload.attributes
        true
      end.returns(success: true)
      AkahuItem.any_instance.expects(:process_accounts).never
      AkahuItem.any_instance.expects(:schedule_account_syncs).never

      assert_raises(Fence::OwnershipChanged) { AkahuItem::Syncer.new(item).perform_sync(sync) }

      assert_equal before_sync, sync.reload.attributes
      assert item.reload.pending_account_setup?
    end
  end

  test "an admitted ownership denial propagates unchanged without collecting an error statistic" do
    with_source do |item, _source, _account, sync|
      error = Fence::OwnershipChanged.new("Original owner lost")
      AkahuItem.any_instance.expects(:import_latest_akahu_data).raises(error)
      AkahuItem::Syncer.any_instance.expects(:collect_health_stats).never
      before_stats = sync.sync_stats

      assert_same error, assert_raises(Fence::OwnershipChanged) { AkahuItem::Syncer.new(item).perform_sync(sync) }

      assert_equal before_stats, sync.reload.sync_stats
      assert item.reload.pending_account_setup?
    end
  end

  test "scheduled source deletion and an enclosing row transaction refuse before any progress" do
    with_source do |item, _source, _account, sync|
      before_sync = sync.reload.attributes
      Provider::Akahu.expects(:new).never
      ApplicationRecord.transaction do
        assert_raises(ArgumentError) { AkahuItem::Syncer.new(item).perform_sync(sync) }
      end
      item.update!(scheduled_for_deletion: true)
      assert_raises(Fence::OwnershipChanged) { AkahuItem::Syncer.new(item).perform_sync(sync) }

      assert_equal before_sync, sync.reload.attributes
      assert item.reload.pending_account_setup?
    end
  end

  test "a contended Sync progress row refuses before import without being converted into SafeSyncError" do
    with_source do |item, _source, _account, sync|
      Provider::Akahu.expects(:new).never
      before = [ item.reload.attributes, sync.reload.attributes ]
      with_other_session_lock(sync) do
        assert_raises(Fence::Busy) { AkahuItem::Syncer.new(item).perform_sync(sync) }
      end
      assert_equal before, [ item.reload.attributes, sync.reload.attributes ]
    end
  end

  private
    def with_source
      with_provider_encryption do
        family = Family.create!(name: "Akahu sync admission")
        item = family.akahu_items.create!(name: "Akahu", app_token: "original-app", user_token: "original-user", pending_account_setup: true)
        source = item.akahu_accounts.create!(name: "Checking", account_id: "account-1", currency: "NZD", current_balance: 25)
        account = family.accounts.create!(name: "Checking", balance: 10, currency: "NZD", accountable: Depository.new)
        AccountProvider.create!(account: account, provider: source)
        sync = item.syncs.create!
        yield item, source, account, sync
      ensure
        if family
          ProviderMigrationControl.where(family_id: family.id).delete_all
          Sync.where(syncable_type: "AkahuItem", syncable_id: family.akahu_items.select(:id)).delete_all
          Sync.where(syncable_type: "Family", syncable_id: family.id).delete_all
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          family.accounts.each(&:destroy!)
          AkahuAccount.where(akahu_item_id: family.akahu_items.select(:id)).delete_all
          family.akahu_items.delete_all
          family.destroy!
        end
      end
    end

    def account_snapshot
      { _id: "account-1", name: "Checking", type: "CHECKING", status: "ACTIVE", balance: { currency: "NZD", current: "55.25" } }
    end

    def transaction
      { "_id" => "posted-1", "_account" => "account-1", "date" => 1.day.ago.to_date.iso8601,
        "amount" => "-12.50", "description" => "Akahu purchase", "type" => "DEBIT" }
    end

    def assert_transport_and_permit(item)
      assert_equal 0, ApplicationRecord.connection.open_transactions
      assert_equal :busy, drain_in_another_session(item)
      true
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

    def with_other_session_lock(sync)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      ready, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Sync.transaction do
            Sync.lock("FOR UPDATE").find(sync.id)
            ready << true
            release.pop
          end
        end
      rescue Exception => error
        ready << error
      end
      acquired = Timeout.timeout(5) { ready.pop }
      raise acquired if acquired.is_a?(Exception)
      yield
    ensure
      release << true if release
      worker.join(5) if worker
      worker&.kill if worker&.alive?
      worker&.join
    end
end
