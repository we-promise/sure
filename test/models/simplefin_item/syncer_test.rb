require "test_helper"

class SimplefinItem::SyncerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "SimpleFIN Syncer Test",
      access_url: "https://example.com/simplefin/access"
    )
    @account, @simplefin_account = create_linked_account(
      name: "SimpleFIN Linked Checking",
      account_id: "sf-syncer-checking"
    )
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "full sync waits for account child syncs before completing" do
    sync = Sync.create!(syncable: @simplefin_item)
    stub_full_simplefin_sync(sync)

    assert_difference -> { @account.syncs.reload.count }, 1 do
      sync.perform
    end

    child_sync = @account.syncs.find_by!(parent: sync)

    assert_equal "syncing", sync.reload.status
    assert_equal "pending", child_sync.status
    assert_nil @simplefin_item.reload.last_synced_at

    stub_account_sync_callbacks
    stub_simplefin_provider_refresh
    SimplefinItem.any_instance.stubs(:broadcast_sync_complete)
    Account.any_instance.expects(:perform_sync).with(child_sync).once

    child_sync.perform

    assert_equal "completed", child_sync.reload.status
    assert_equal "completed", sync.reload.status
    assert_not_nil @simplefin_item.reload.last_synced_at
  end

  test "failed account child sync fails simplefin and family parents" do
    family_sync = Sync.create!(syncable: @family)
    family_sync.start!

    sync = Sync.create!(syncable: @simplefin_item, parent: family_sync)
    assert_nil @simplefin_item.last_synced_at
    stub_full_simplefin_sync(sync)

    assert_difference -> { @account.syncs.reload.count }, 1 do
      sync.perform
    end

    child_sync = @account.syncs.find_by!(parent: sync)

    assert_equal "syncing", sync.reload.status
    assert_equal "syncing", family_sync.reload.status

    stub_sync_callbacks
    Account.any_instance
      .expects(:perform_sync)
      .with(child_sync)
      .raises(StandardError.new("balance materialization failed"))

    child_sync.perform

    assert_equal "failed", child_sync.reload.status
    assert_equal "failed", sync.reload.status
    assert_equal "failed", family_sync.reload.status
    assert_nil @simplefin_item.reload.last_synced_at
  end

  test "full sync registers all child syncs before enqueueing account jobs" do
    create_linked_account(
      name: "SimpleFIN Linked Savings",
      account_id: "sf-syncer-savings"
    )

    sync = Sync.create!(syncable: @simplefin_item)
    stub_full_simplefin_sync(sync)
    stub_sync_callbacks
    Account.any_instance.stubs(:perform_sync)

    enqueued_child_syncs = []

    SyncJob.expects(:perform_later).twice.with do |child_sync|
      assert_equal 2, sync.children.reload.count
      enqueued_child_syncs << child_sync
      true
    end

    sync.perform

    assert_equal 2, enqueued_child_syncs.size

    enqueued_child_syncs.first.perform

    child_statuses = sync.children.reload.map(&:status)

    assert_equal 1, child_statuses.count("completed")
    assert_equal 1, child_statuses.count("pending")
    assert_equal "syncing", sync.reload.status
  end

  test "schedule account syncs removes deferred children when enqueue fails" do
    create_linked_account(
      name: "SimpleFIN Linked Savings",
      account_id: "sf-syncer-savings"
    )

    sync = Sync.create!(syncable: @simplefin_item)

    SyncJob.expects(:perform_later).once.with do |_child_sync|
      assert_equal 2, sync.children.reload.count
      true
    end.raises(StandardError.new("queue unavailable"))

    error = assert_raises(StandardError) do
      @simplefin_item.schedule_account_syncs(parent_sync: sync)
    end

    assert_equal "queue unavailable", error.message
    assert_equal 0, sync.children.reload.count
  end

  private
    def create_linked_account(name:, account_id:)
      account = Account.create!(
        family: @family,
        owner: users(:family_admin),
        name: name,
        balance: 100,
        currency: "USD",
        accountable: Depository.create!(subtype: "checking")
      )
      simplefin_account = @simplefin_item.simplefin_accounts.create!(
        name: name,
        account_id: account_id,
        currency: "USD",
        account_type: "checking",
        current_balance: 100
      )

      AccountProvider.create!(account: account, provider: simplefin_account)

      [ account, simplefin_account ]
    end

    def stub_full_simplefin_sync(sync)
      @simplefin_item.stubs(:import_latest_simplefin_data).with(sync: sync)
      @simplefin_item.stubs(:process_accounts).returns([])
    end

    def stub_account_sync_callbacks
      Account.any_instance.stubs(:perform_post_sync)
      Account.any_instance.stubs(:broadcast_sync_complete)
    end

    def stub_simplefin_provider_refresh
      ApplicationController.stubs(:render).returns("<div></div>")
      Turbo::StreamsChannel.expects(:broadcast_replace_to).once
      Family.any_instance.expects(:broadcast_refresh).once
    end

    def stub_sync_callbacks
      stub_account_sync_callbacks
      SimplefinItem.any_instance.stubs(:perform_post_sync)
      SimplefinItem.any_instance.stubs(:broadcast_sync_complete)
      Family.any_instance.stubs(:perform_post_sync)
      Family.any_instance.stubs(:broadcast_sync_complete)
    end
end
