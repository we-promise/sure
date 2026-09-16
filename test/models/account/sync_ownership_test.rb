require "test_helper"
require "timeout"

class Account::SyncOwnershipTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @owner = users(:family_member)
    @admin = users(:family_admin)
    @account = @family.accounts.create!(owner: @owner, name: "Private retained account", currency: "USD",
      balance: 0, accountable: Depository.new)
    DebugLogEntry.stubs(:capture)
  end

  test "new account executions capture the fresh family instead of a cached association" do
    original_family = @account.family_id
    reparent_account

    sync = Sync.create!(syncable: @account)

    assert_equal original_family, @account.family_id
    assert_equal families(:empty).id, sync.account_family_id
    assert_equal families(:empty), sync.send(:family)
    assert_equal sync.account_family_id, sync.reload.account_family_id
  end

  test "new executions reject supplied foreign ownership and family fields on non-account owners" do
    account_sync = Sync.new(syncable: @account, account_family_id: families(:empty).id)
    refute account_sync.valid?
    assert account_sync.errors[:account_family].present?

    family_sync = Sync.new(syncable: @family, account_family_id: @family.id)
    refute family_sync.valid?
    assert family_sync.errors[:account_family].present?
  end

  test "model capture refuses missing and unavailable financial accounts" do
    %w[pending_deletion unknown].each do |state|
      Account.where(id: @account.id).update_all(status: state)
      sync = Sync.new(syncable: @account)
      refute sync.valid?
      assert_nil sync.account_family_id
    end
    Account.where(id: @account.id).delete_all
    sync = Sync.new(syncable: @account)
    refute sync.valid?
    assert_nil sync.account_family_id
  end

  test "a historical unknown binding is neither inferred during validation nor used to retry" do
    original = @account.syncs.create!
    # Historical NULL rows can predate the migration. New INSERTs deliberately
    # cannot manufacture one for a live account, so load its old scalar shape.
    unknown = Sync.instantiate(original.attributes.merge("account_family_id" => nil, "status" => "failed"))
    Account::SyncAdmission.expects(:current).never
    Account::SyncQueue.expects(:new).never
    Account::SyncInput.any_instance.expects(:payload).never

    unknown.error = "An earlier execution failed"
    assert unknown.valid?
    assert unknown.valid?(:create)
    assert_nil unknown.account_family_id
    assert_nil unknown.send(:family)
    assert_raises(Account::SyncAdmission::Unavailable) { unknown.retry_account_later }
  end

  test "account history preserves live owner and share permissions without an admin fallback" do
    sync = @account.syncs.create!(status: "completed")

    assert_includes Sync.for_family(@family, resource_owner: @owner), sync
    assert_not_includes Sync.for_family(@family, resource_owner: @admin), sync
    @account.share_with!(@admin, permission: "read_only")
    assert_includes Sync.for_family(@family, resource_owner: @admin), sync
    @account.unshare_with!(@admin)
    assert_not_includes Sync.for_family(@family, resource_owner: @admin), sync
    assert_includes Sync.for_family(@family), sync
  end

  test "a resource owner from another family cannot use the family history entry point" do
    @family.syncs.create!(status: "completed")
    @account.syncs.create!(status: "completed")

    assert_empty Sync.for_family(@family, resource_owner: users(:empty))
  end

  test "retired history stays internally discoverable without granting former users access" do
    sync = @account.syncs.create!(status: "completed", completed_at: Time.current)
    Account::IngestionIdentity.capture!(account: @account)
    retire_account
    Account::SyncInput.any_instance.expects(:payload).never
    Account::SyncPreparation.any_instance.expects(:payload).never
    retained = Sync.find(sync.id)

    assert_nil retained.syncable
    assert_equal @family, retained.send(:family)
    assert_includes Sync.for_family(@family), retained
    assert_not_includes Sync.for_family(families(:empty)), retained
    [ @owner, @admin ].each do |user|
      assert_not_includes Sync.for_family(@family, resource_owner: user), retained
    end
  end

  test "missing live accounts retain their captured family without requiring a new identity" do
    sync = @account.syncs.create!(status: "completed")
    Account.where(id: @account.id).delete_all

    refute Account::IngestionIdentity.exists?(id: @account.id)
    assert_equal @family, Sync.find(sync.id).send(:family)
    assert_includes Sync.for_family(@family), sync
    assert_not_includes Sync.for_family(@family, resource_owner: @owner), sync
  end

  test "a changed live family cannot acquire earlier account history or activity" do
    original = @account.syncs.create!(status: "completed", completed_at: Time.current)
    reparent_account
    current = Account.find(@account.id)

    assert_equal @family, original.send(:family)
    assert_includes Sync.for_family(@family), original
    assert_not_includes Sync.for_family(@family, resource_owner: @owner), original
    assert_not_includes Sync.for_family(current.family, resource_owner: users(:empty)), original
    assert_nil Sync.latest_by_syncable([ current ]).fetch([ "Account", current.id ])
    assert_nil Sync.latest_completed_by_syncable([ current ]).fetch([ "Account", current.id ])

    latest = current.syncs.create!(status: "completed", completed_at: Time.current)
    assert_equal latest, Sync.latest_completed_by_syncable([ current ]).fetch([ "Account", current.id ])
    assert_not_includes Sync.for_family(@family), latest

    loaded = Account.includes(:syncs).find(current.id)
    assert loaded.association(:syncs).loaded?
    assert_equal [ latest.id ], loaded.syncs.map(&:id)
    Current.stubs(:latest_sync_by_syncable).returns(nil)
    Current.stubs(:latest_completed_sync_by_syncable).returns(nil)
    assert_equal latest, loaded.latest_sync_record
    assert_equal latest, loaded.latest_completed_sync_record
  end

  test "active work excludes unavailable account owners while history retains them" do
    isolated = Family.create!(name: "Ownership activity scope")
    account = isolated.accounts.create!(name: "Activity owner", currency: "USD", balance: 0, accountable: Depository.new)
    sync = account.syncs.create!

    %w[active draft disabled].each do |state|
      Account.where(id: account.id).update_all(status: state)
      assert Sync.any_incomplete_for?(isolated), state
    end
    [ "pending_deletion", "unknown", nil ].each do |state|
      Account.where(id: account.id).update_all(status: state)
      refute Sync.any_incomplete_for?(isolated), state.inspect
      assert_includes Sync.for_family(isolated), sync
    end
    Account.where(id: account.id).delete_all
    refute Sync.any_incomplete_for?(isolated)
    assert_includes Sync.for_family(isolated), sync

    family_sync = isolated.syncs.create!
    assert Sync.any_incomplete_for?(isolated)
    assert_includes Sync.for_family(isolated), family_sync
  end

  test "retry refuses a changed family before reading its retained input or scheduling work" do
    sync = @account.sync_later
    sync.update!(status: "failed")
    reparent_account
    Account::SyncInput.any_instance.expects(:payload).never
    Account::SyncQueue.expects(:new).never

    assert_no_enqueued_jobs do
      assert_raises(Account::SyncAdmission::Unavailable) { sync.retry_account_later }
    end
    assert_equal @family.id, sync.reload.account_family_id
  end

  test "finalization rejects a changed family and preserves the original ownership" do
    sync = @account.syncs.create!(status: "syncing", syncing_at: Time.current)
    reparent_account
    Account.any_instance.expects(:perform_post_sync).never
    Account.any_instance.expects(:broadcast_sync_complete).never

    assert_no_enqueued_jobs { sync.finalize_if_all_children_finalized }

    assert sync.reload.stale?
    assert_equal @family.id, sync.account_family_id
    assert_nil sync.completed_at
    assert_nil sync.post_sync_completed_at
  end

  test "clean settles missing and retired account owners without input reads or completion callbacks" do
    missing = @account.syncs.create!(created_at: 2.days.ago)
    Account.where(id: @account.id).delete_all
    retired_account = @family.accounts.create!(owner: @owner, name: "Retired cleaner owner", currency: "USD",
      balance: 0, accountable: Depository.new)
    retired = retired_account.syncs.create!(created_at: 2.days.ago, status: "syncing", syncing_at: 2.days.ago)
    Account::IngestionIdentity.capture!(account: retired_account)
    retire_account(retired_account)
    Account::SyncInput.any_instance.expects(:payload).never
    Account.any_instance.expects(:perform_post_sync).never
    Account.any_instance.expects(:broadcast_sync_complete).never

    assert_no_enqueued_jobs { Sync.clean }

    [ missing, retired ].each do |sync|
      assert sync.reload.stale?
      assert_equal @family.id, sync.account_family_id
      assert_nil sync.account_inputs_sealed_at
      assert_nil sync.post_sync_completed_at
      assert sync.error.present?
    end
  end

  test "family and provider history keep their existing scope without account-family metadata" do
    family_sync = @family.syncs.create!(status: "completed")
    provider_sync = plaid_items(:one).syncs.create!(status: "completed")

    [ family_sync, provider_sync ].each do |sync|
      assert_nil sync.account_family_id
      assert_equal @family, sync.send(:family)
      assert_includes Sync.for_family(@family, resource_owner: @owner), sync
    end
    assert_equal [ family_sync.id, provider_sync.id ].sort,
      Sync.for_syncables([ @family, plaid_items(:one) ]).where(id: [ family_sync.id, provider_sync.id ]).ids.sort
    loaded_provider = PlaidItem.includes(:syncs).find(plaid_items(:one).id)
    assert loaded_provider.association(:syncs).loaded?
    assert_includes loaded_provider.syncs, provider_sync
  end

  private
    def reparent_account
      Account.where(id: @account.id).update_all(family_id: families(:empty).id, owner_id: users(:empty).id)
    end

    def retire_account(account = @account)
      # A rollback-only database fixture, not a retirement command. Retained
      # Sync rows remain; the test transaction removes this entire fixture.
      ApplicationRecord.transaction(requires_new: true) do
        Account::IngestionIdentity.where(id: account.id).update_all(live_account_id: nil, retired_at: Time.current)
        Account.where(id: account.id).delete_all
        ApplicationRecord.connection.execute("SET CONSTRAINTS account_ingestion_identity_retirement IMMEDIATE")
      end
    end
end

class Account::SyncOwnershipExecutionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "the real worker refuses an account that moved away from its captured family" do
    with_owner do |account, family, other_family|
      sync = account.syncs.create!
      original = sync.attributes.slice("pending_at", "account_inputs_digest", "account_inputs_sealed_at")
      Account.where(id: account.id).update_all(family_id: other_family.id)
      Account.any_instance.expects(:perform_sync).never
      Account.any_instance.expects(:perform_post_sync).never
      Account::SyncQueue.any_instance.expects(:seal_existing!).never

      assert_no_enqueued_jobs { SyncJob.perform_now(sync) }

      assert sync.reload.stale?
      assert_equal family.id, sync.account_family_id
      assert_equal original, sync.attributes.slice(*original.keys)
      assert_nil sync.syncing_at
      assert_nil sync.post_sync_completed_at
    end
  end

  test "a busy duplicate does not requeue after the live account changes family" do
    with_owner do |account, family, other_family|
      sync = account.syncs.create!
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
        Account.where(id: account.id).update_all(family_id: other_family.id)
        original = sync.reload.attributes

        assert_no_enqueued_jobs { Account::SyncExecution.with(sync) { flunk "duplicate worker was admitted" } }

        assert_equal original, sync.reload.attributes
        assert_equal family.id, sync.account_family_id
      ensure
        release << true
        Timeout.timeout(5) { holder.value }
      end
    end
  end

  private
    def with_owner
      family = Family.create!(name: "Original account execution family")
      other_family = Family.create!(name: "Changed account execution family")
      account = family.accounts.create!(name: "Captured owner", currency: "USD", balance: 0, accountable: Depository.new)
      yield account, family, other_family
    ensure
      if account
        Sync.where(syncable_type: "Account", syncable_id: account.id).destroy_all
        Account.find(account.id).destroy! if Account.exists?(account.id)
      end
      family&.destroy!
      other_family&.destroy!
      clear_enqueued_jobs
    end
end
