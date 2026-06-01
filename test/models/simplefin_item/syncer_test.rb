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
    @account = Account.create!(
      family: @family,
      owner: users(:family_admin),
      name: "SimpleFIN Linked Checking",
      balance: 100,
      currency: "USD",
      accountable: Depository.create!(subtype: "checking")
    )
    @simplefin_account = @simplefin_item.simplefin_accounts.create!(
      name: "SimpleFIN Checking",
      account_id: "sf-syncer-checking",
      currency: "USD",
      account_type: "checking",
      current_balance: 100
    )

    AccountProvider.create!(account: @account, provider: @simplefin_account)
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

    stub_sync_callbacks
    Account.any_instance.expects(:perform_sync).with(child_sync).once

    child_sync.perform

    assert_equal "completed", child_sync.reload.status
    assert_equal "completed", sync.reload.status
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

  private
    def stub_full_simplefin_sync(sync)
      @simplefin_item.stubs(:import_latest_simplefin_data).with(sync: sync)
      @simplefin_item.stubs(:process_accounts).returns([])
    end

    def stub_sync_callbacks
      Account.any_instance.stubs(:perform_post_sync)
      Account.any_instance.stubs(:broadcast_sync_complete)
      SimplefinItem.any_instance.stubs(:perform_post_sync)
      SimplefinItem.any_instance.stubs(:broadcast_sync_complete)
      Family.any_instance.stubs(:perform_post_sync)
      Family.any_instance.stubs(:broadcast_sync_complete)
    end
end
