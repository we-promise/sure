require "test_helper"

class CoinstatsItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @coinstats_item = CoinstatsItem.create!(
      family: @family,
      name: "Test CoinStats Connection",
      api_key: "test_api_key_123"
    )
    @syncer = CoinstatsItem::Syncer.new(@coinstats_item)
  end

  test "perform_sync imports data from coinstats api" do
    mock_sync = mock("sync")
    mock_sync.stubs(:respond_to?).with(:status_text).returns(true)
    mock_sync.stubs(:respond_to?).with(:sync_stats).returns(true)
    mock_sync.stubs(:window_start_date).returns(nil)
    mock_sync.stubs(:window_end_date).returns(nil)
    mock_sync.expects(:update!).at_least_once

    @coinstats_item.expects(:import_latest_coinstats_data).once

    @syncer.perform_sync(mock_sync)
  end

  test "perform_sync updates pending_account_setup when unlinked accounts exist" do
    # Create an unlinked coinstats account (no AccountProvider)
    @coinstats_item.coinstats_accounts.create!(
      name: "Unlinked Wallet",
      currency: "USD"
    )

    mock_sync = mock("sync")
    mock_sync.stubs(:respond_to?).with(:status_text).returns(true)
    mock_sync.stubs(:respond_to?).with(:sync_stats).returns(true)
    mock_sync.stubs(:window_start_date).returns(nil)
    mock_sync.stubs(:window_end_date).returns(nil)
    mock_sync.expects(:update!).at_least_once

    @coinstats_item.expects(:import_latest_coinstats_data).once

    @syncer.perform_sync(mock_sync)

    assert @coinstats_item.reload.pending_account_setup?
  end

  test "perform_sync clears pending_account_setup when all accounts linked" do
    @coinstats_item.update!(pending_account_setup: true)

    # Create a linked coinstats account
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Crypto",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Linked Wallet",
      currency: "USD"
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    mock_sync = mock("sync")
    mock_sync.stubs(:respond_to?).with(:status_text).returns(true)
    mock_sync.stubs(:respond_to?).with(:sync_stats).returns(true)
    mock_sync.stubs(:sync_stats).returns({})
    mock_sync.stubs(:window_start_date).returns(nil)
    mock_sync.stubs(:window_end_date).returns(nil)
    mock_sync.expects(:update!).at_least_once

    @coinstats_item.expects(:import_latest_coinstats_data).once
    @coinstats_item.expects(:process_accounts).once
    @coinstats_item.expects(:schedule_account_syncs).once

    @syncer.perform_sync(mock_sync)

    refute @coinstats_item.reload.pending_account_setup?
  end

  test "perform_sync processes accounts when linked accounts exist" do
    # Create a linked coinstats account
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Crypto",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Linked Wallet",
      currency: "USD"
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    mock_sync = mock("sync")
    mock_sync.stubs(:respond_to?).with(:status_text).returns(true)
    mock_sync.stubs(:respond_to?).with(:sync_stats).returns(true)
    mock_sync.stubs(:sync_stats).returns({})
    mock_sync.stubs(:window_start_date).returns(nil)
    mock_sync.stubs(:window_end_date).returns(nil)
    mock_sync.expects(:update!).at_least_once

    @coinstats_item.expects(:import_latest_coinstats_data).once
    @coinstats_item.expects(:process_accounts).once
    @coinstats_item.expects(:schedule_account_syncs).with(
      parent_sync: mock_sync,
      window_start_date: nil,
      window_end_date: nil
    ).once

    @syncer.perform_sync(mock_sync)
  end

  test "perform_sync skips processing when no linked accounts" do
    mock_sync = mock("sync")
    mock_sync.stubs(:respond_to?).with(:status_text).returns(true)
    mock_sync.stubs(:respond_to?).with(:sync_stats).returns(true)
    mock_sync.stubs(:window_start_date).returns(nil)
    mock_sync.stubs(:window_end_date).returns(nil)
    mock_sync.expects(:update!).at_least_once

    @coinstats_item.expects(:import_latest_coinstats_data).once
    @coinstats_item.expects(:process_accounts).never
    @coinstats_item.expects(:schedule_account_syncs).never

    @syncer.perform_sync(mock_sync)
  end

  test "perform_sync records sync stats" do
    # Create one linked and one unlinked account
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Crypto",
      balance: 1000,
      currency: "USD"
    )
    linked_account = @coinstats_item.coinstats_accounts.create!(
      name: "Linked Wallet",
      currency: "USD"
    )
    AccountProvider.create!(account: account, provider: linked_account)

    @coinstats_item.coinstats_accounts.create!(
      name: "Unlinked Wallet",
      currency: "USD"
    )

    recorded_stats = nil
    mock_sync = mock("sync")
    mock_sync.stubs(:respond_to?).with(:status_text).returns(true)
    mock_sync.stubs(:respond_to?).with(:sync_stats).returns(true)
    mock_sync.stubs(:sync_stats).returns({})
    mock_sync.stubs(:window_start_date).returns(nil)
    mock_sync.stubs(:window_end_date).returns(nil)
    mock_sync.expects(:update!).at_least_once.with do |args|
      recorded_stats = args[:sync_stats] if args.key?(:sync_stats)
      true
    end

    @coinstats_item.expects(:import_latest_coinstats_data).once
    @coinstats_item.expects(:process_accounts).once
    @coinstats_item.expects(:schedule_account_syncs).once

    @syncer.perform_sync(mock_sync)

    assert_equal 2, recorded_stats[:total_accounts]
    assert_equal 1, recorded_stats[:linked_accounts]
    assert_equal 1, recorded_stats[:unlinked_accounts]
  end

  test "perform_post_sync is a no-op" do
    # Just ensure it doesn't raise
    assert_nothing_raised do
      @syncer.perform_post_sync
    end
  end
end
