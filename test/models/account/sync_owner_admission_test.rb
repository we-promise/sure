require "test_helper"
require "timeout"

class Account::SyncOwnerAdmissionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Context = Data.define(:family, :account)
  RETAINED_FIELDS = %w[pending_at syncing_at completed_at failed_at post_sync_completed_at account_inputs_sealed_at
    account_inputs_digest account_materialized_at account_request_key predecessor_id window_start_date window_end_date].freeze

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "a deleted legacy owner is terminalized before any empty seal or work can be invented" do
    with_owner do |context|
      sync = context.account.syncs.create!
      assert_equal context.account, sync.syncable
      original = sync.attributes.slice(*RETAINED_FIELDS)
      Account.where(id: context.account.id).delete_all
      forbid_work

      assert_no_enqueued_jobs { SyncJob.perform_now(sync) }

      assert_unavailable(sync, original)
      assert_nil sync.account_inputs_sealed_at
      assert_nil sync.account_inputs_digest
      assert_nil sync.syncing_at
      assert_empty sync.account_sync_inputs
    end
  end

  test "a deleted owner cannot reset a running sealed calculation or lose its materialization marker" do
    with_owner do |context|
      sync = context.account.sync_later
      sync.start!
      sync.update!(account_materialized_at: Time.current)
      original = sync.reload.attributes.slice(*RETAINED_FIELDS)
      Account.where(id: context.account.id).delete_all
      clear_enqueued_jobs
      forbid_work

      assert_no_enqueued_jobs { sync.perform }

      assert_unavailable(sync, original)
      assert sync.account_materialized_at
      assert sync.account_inputs_sealed_at
    end
  end

  test "fresh pending-deletion admission refuses pending and running sealed or unsealed jobs" do
    [ false, true ].product([ false, true ]).each do |sealed, running|
      with_owner do |context|
        sync = sealed ? context.account.sync_later : context.account.syncs.create!
        sync.start! if running
        original = sync.reload.attributes.slice(*RETAINED_FIELDS)
        sync.syncable # Cache the formerly eligible receiver before the write.
        Account.where(id: context.account.id).update_all(status: "pending_deletion")
        clear_enqueued_jobs
        forbid_work

        assert_no_enqueued_jobs { SyncJob.perform_now(sync) }

        assert_unavailable(sync, original)
        assert context.account.reload.pending_deletion?
      end
    end
  end

  test "a retired identity and missing live Account preserve their queued execution history without running" do
    with_owner do |context|
      sync = context.account.sync_later
      identity = Account::IngestionIdentity.capture!(account: context.account)
      original = sync.reload.attributes.slice(*RETAINED_FIELDS)
      retire_fixture(context.account)
      clear_enqueued_jobs
      forbid_work

      assert_no_enqueued_jobs { SyncJob.perform_now(sync) }

      assert_unavailable(sync, original)
      assert identity.reload.retired?
      assert_nil identity.live_account_id
      refute Account.exists?(context.account.id)
    end
  end

  test "unavailable admission neither dispatches the successor nor finalizes the parent" do
    with_owner do |context|
      parent = context.family.syncs.create!(status: "syncing", syncing_at: Time.current)
      sync = context.account.syncs.create!(parent: parent, status: "syncing", syncing_at: Time.current)
      successor = context.account.syncs.create!(predecessor: sync)
      parent_before, successor_before = parent.attributes, successor.attributes
      retained = sync.attributes.slice(*RETAINED_FIELDS)
      Account.where(id: context.account.id).update_all(status: "pending_deletion")
      forbid_work
      Family.any_instance.expects(:perform_post_sync).never
      Family.any_instance.expects(:broadcast_sync_complete).never

      assert_no_enqueued_jobs { SyncJob.perform_now(sync) }

      assert_unavailable(sync, retained)
      assert_equal parent_before, parent.reload.attributes
      assert_equal successor_before, successor.reload.attributes
      assert successor.pending?
    end
  end

  test "already terminal executions remain byte-for-byte unchanged when the owner is gone" do
    %w[completed failed stale].each do |state|
      with_owner do |context|
        attributes = { status: state }
        attributes["#{state}_at"] = Time.current unless state == "stale"
        sync = context.account.syncs.create!(attributes)
        original = sync.reload.attributes
        Account.where(id: context.account.id).delete_all
        forbid_work

        assert_no_enqueued_jobs { SyncJob.perform_now(sync) }

        assert_equal original, sync.reload.attributes
      end
    end
  end

  test "a valid execution replaces the stale cached owner and starts work outside row transactions" do
    with_owner do |context|
      sync = context.account.syncs.create!
      assert_equal "Private queued account", sync.syncable.name
      Account.where(id: context.account.id).update_all(name: "Fresh admitted account")
      seen = []
      Account.any_instance.expects(:perform_sync).with do |current_sync|
        seen << [ current_sync.syncable.id, current_sync.syncable.name, ApplicationRecord.connection.open_transactions ]
        true
      end.once
      Account.any_instance.stubs(:perform_post_sync)
      Account.any_instance.stubs(:broadcast_sync_complete)

      SyncJob.perform_now(sync)

      assert_equal [ [ context.account.id, "Fresh admitted account", 0 ] ], seen
      assert sync.reload.completed?
      assert sync.account_inputs_sealed_at
      assert_empty sync.verify_account_inputs!
    end
  end

  test "admission accepts only current supported statuses and the expected family" do
    with_owner do |context|
      %w[active draft disabled].each do |status|
        Account.where(id: context.account.id).update_all(status: status)
        current = Account::SyncAdmission.fetch!(account_id: context.account.id, family_id: context.family.id)
        assert_equal status, current.status
        assert_equal context.account.id, current.id
        refute_same context.account, current
      end
      assert_nil Account::SyncAdmission.current(account_id: context.account.id, family_id: SecureRandom.uuid)
      assert_raises(Account::SyncAdmission::Unavailable) do
        Account::SyncAdmission.fetch!(account_id: context.account.id, family_id: SecureRandom.uuid)
      end
      [ "pending_deletion", nil, "unknown" ].each do |status|
        Account.where(id: context.account.id).update_all(status: status)
        assert_nil Account::SyncAdmission.current(account_id: context.account.id)
        assert_raises(Account::SyncAdmission::Unavailable) do
          Account::SyncAdmission.fetch!(account_id: context.account.id)
        end
      end
    ensure
      Account.where(id: context.account.id).update_all(status: "active")
    end
  end

  test "a duplicate worker cannot requeue an owner that became pending deletion while the session lock is busy" do
    with_owner do |context|
      sync = context.account.sync_later
      entered, release = Queue.new, Queue.new
      holder = Thread.new do
        begin
          Account::SyncExecution.with(Sync.find(sync.id)) do
            entered << :held
            release.pop
          end
        rescue Exception => error
          entered << error
          raise
        end
      end
      begin
        observed = Timeout.timeout(5) { entered.pop }
        raise observed if observed.is_a?(Exception)
        assert_equal :held, observed
        Account.where(id: context.account.id).update_all(status: "pending_deletion")
        original = sync.reload.attributes
        clear_enqueued_jobs
        forbid_work

        assert_no_enqueued_jobs { SyncJob.perform_now(sync) }

        assert_equal original, sync.reload.attributes
      ensure
        release << true
        Timeout.timeout(5) { holder.value }
      end
    end
  end

  test "direct finalization refuses unavailable owners without completing work or propagating to their parent" do
    %w[syncing completed].each do |state|
      with_owner do |context|
        parent = context.family.syncs.create!(status: "syncing", syncing_at: Time.current)
        sync = context.account.syncs.create!(parent: parent, status: state, syncing_at: Time.current,
          completed_at: state == "completed" ? Time.current : nil)
        original, parent_before = sync.reload.attributes, parent.reload.attributes
        Account.where(id: context.account.id).update_all(status: "pending_deletion")
        forbid_work
        Family.any_instance.expects(:perform_post_sync).never
        Family.any_instance.expects(:broadcast_sync_complete).never

        assert_no_enqueued_jobs { sync.finalize_if_all_children_finalized }

        if state == "syncing"
          assert_unavailable(sync, original.slice(*RETAINED_FIELDS))
        else
          assert_equal original, sync.reload.attributes
        end
        assert_nil sync.post_sync_completed_at
        assert_equal parent_before, parent.reload.attributes
      end
    end
  end

  test "child finalization propagates to its parent only after an enclosing transaction commits" do
    with_owner do |context|
      parent = context.family.syncs.create!(status: "syncing", syncing_at: Time.current)
      child = context.account.syncs.create!(parent: parent, status: "syncing", syncing_at: Time.current)
      parent_transactions = []
      Account.any_instance.expects(:perform_post_sync).once
      Account.any_instance.stubs(:broadcast_sync_complete)
      Family.any_instance.expects(:perform_post_sync).with do
        parent_transactions << ApplicationRecord.connection.open_transactions
        true
      end.once
      Family.any_instance.stubs(:broadcast_sync_complete)

      Sync.transaction do
        child.finalize_if_all_children_finalized
        assert child.reload.completed?
        assert child.post_sync_completed_at
        assert parent.reload.syncing?
        assert_nil parent.post_sync_completed_at
        assert_empty parent_transactions
      end

      assert parent.reload.completed?
      assert parent.post_sync_completed_at
      assert_equal [ 1 ], parent_transactions, "parent work should own only its own finalization transaction"
    end
  end

  test "rolled-back child finalization never propagates to its parent or commits completion markers" do
    with_owner do |context|
      parent = context.family.syncs.create!(status: "syncing", syncing_at: Time.current)
      child = context.account.syncs.create!(parent: parent, status: "syncing", syncing_at: Time.current)
      original, parent_before = child.reload.attributes, parent.reload.attributes
      Account.any_instance.expects(:perform_post_sync).once
      Account.any_instance.stubs(:broadcast_sync_complete)
      Family.any_instance.expects(:perform_post_sync).never
      Family.any_instance.expects(:broadcast_sync_complete).never

      assert_no_enqueued_jobs do
        Sync.transaction do
          child.finalize_if_all_children_finalized
          assert child.reload.completed?
          assert child.post_sync_completed_at
          assert parent.reload.syncing?
          raise ActiveRecord::Rollback
        end
      end

      assert_equal original, child.reload.attributes
      assert_equal parent_before, parent.reload.attributes
    end
  end

  test "queue preflight rejects stale missing pending and retired receivers before reading selected inputs" do
    %i[missing pending retired].each do |state|
      with_owner do |context|
        make_unavailable(context.account, state)
        before = [ Sync.count, Account::SyncInput.count, Account::SyncSource.count ]
        queries = nil

        assert_no_enqueued_jobs do
          queries = capture_sql_queries do
            assert_raises(Account::SyncAdmission::Unavailable) { Account::SyncQueue.new(context.account).enqueue }
          end
        end

        assert_equal before, [ Sync.count, Account::SyncInput.count, Account::SyncSource.count ]
        assert_empty queries.grep(/FROM\s+"account_sync_(?:inputs|sources)"/i)
      end
    end
  end

  test "seal_existing rechecks an unavailable owner even when inputs were already sealed" do
    %i[missing pending retired].product([ false, true ]).each do |state, sealed|
      with_owner do |context|
        sync = sealed ? context.account.sync_later : context.account.syncs.create!
        original = sync.reload.attributes
        make_unavailable(context.account, state)
        clear_enqueued_jobs

        assert_no_enqueued_jobs do
          assert_raises(Account::SyncAdmission::Unavailable) { Account::SyncQueue.new(context.account).seal_existing!(sync) }
        end

        assert_equal original, sync.reload.attributes
        assert_empty sync.account_sync_inputs
      end
    end
  end

  test "queue ownership is rechecked after input planning before creating or scheduling a Sync" do
    with_owner do |context|
      queue = Account::SyncQueue.new(context.account)
      changed = false
      queue.define_singleton_method(:requested_inputs) do |**arguments|
        result = super(**arguments)
        unless changed
          Account.where(id: context.account.id).update_all(status: "pending_deletion")
          changed = true
        end
        result
      end
      before = [ Sync.count, Account::SyncInput.count, Account::SyncSource.count ]

      assert_no_enqueued_jobs do
        assert_raises(Account::SyncAdmission::Unavailable) { queue.enqueue }
      end

      assert changed
      assert context.account.reload.pending_deletion?
      assert_equal before, [ Sync.count, Account::SyncInput.count, Account::SyncSource.count ]
    end
  end

  private

    def forbid_work
      Account.any_instance.expects(:perform_sync).never
      Account.any_instance.expects(:perform_post_sync).never
      Account.any_instance.expects(:broadcast_sync_complete).never
      Account::SyncQueue.any_instance.expects(:seal_existing!).never
    end

    def assert_unavailable(sync, retained)
      assert sync.reload.stale?
      assert sync.error.present?
      assert_not_includes sync.error, "Private queued account"
      assert_equal retained, sync.attributes.slice(*RETAINED_FIELDS)
      assert_nil sync.completed_at
      assert_nil sync.post_sync_completed_at
    end

    def make_unavailable(account, state)
      case state
      when :missing then Account.where(id: account.id).delete_all
      when :pending then Account.where(id: account.id).update_all(status: "pending_deletion")
      when :retired
        Account::IngestionIdentity.capture!(account: account)
        retire_fixture(account)
      end
    end

    def retire_fixture(account)
      # A no-financial-input rollback-independent database fixture, not a public
      # retirement command: its original Sync rows remain polymorphic history.
      ApplicationRecord.transaction do
        Account::IngestionIdentity.where(id: account.id).update_all(live_account_id: nil, retired_at: Time.current)
        Account.where(id: account.id).delete_all
        ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement IMMEDIATE")
      end
    end

    def with_owner
      family = Family.create!(name: "Account execution owner admission")
      account = family.accounts.create!(name: "Private queued account", balance: 0, currency: "USD", accountable: Depository.new)
      accountable_id = account.accountable_id
      yield Context.new(family, account)
    ensure
      retired = account && Account::IngestionIdentity.where(id: account.id).where.not(retired_at: nil).exists?
      if account
        Sync.where(syncable_type: "Account", syncable_id: account.id).destroy_all unless retired
        Account.find(account.id).destroy! if Account.exists?(account.id)
        Depository.where(id: accountable_id).destroy_all
      end
      if retired
        # This isolated family contains only no-input execution metadata.
        # The actual Family FK cascade removes its retained identity and Syncs;
        # no retained row is deleted while the owning family still exists.
        family_sync_ids = Sync.where(syncable_type: "Family", syncable_id: family.id).pluck(:id)
        family.delete
        Sync.where(id: family_sync_ids).destroy_all
      else
        family&.syncs&.destroy_all
        family&.destroy!
      end
      clear_enqueued_jobs
    end
end
