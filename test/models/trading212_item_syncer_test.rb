require "test_helper"

class Trading212ItemSyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = trading212_items(:configured_item)
    @syncer = Trading212Item::Syncer.new(@item)
  end

  # === perform_sync (missing credentials) ===

  test "perform_sync raises ConfigurationError when credentials are missing" do
    @item.update!(api_key: nil, api_secret: nil)
    sync = @item.syncs.create!

    error = assert_raises(Provider::Trading212::ConfigurationError) do
      @syncer.perform_sync(sync)
    end

    assert_equal "Trading 212 API key is missing.", error.message
    assert_equal "requires_update", @item.reload.status
  end

  test "perform_sync sets requires_update status on auth error" do
    sync = @item.syncs.create!
    Provider::Trading212.any_instance.expects(:fetch_account_summary)
      .raises(Provider::Trading212::AuthenticationError.new("Trading 212 authentication failed (401)."))

    assert_raises(Provider::Trading212::AuthenticationError) do
      @syncer.perform_sync(sync)
    end

    assert_equal "requires_update", @item.reload.status
  end

  # === perform_sync (happy path) ===

  test "perform_sync imports data and processes accounts when linked" do
    # Link an account
    t212_account = trading212_accounts(:main_account)
    investment = accounts(:investment)
    t212_account.ensure_account_provider!(investment)

    sync = @item.syncs.create!
    @item.update!(status: :good)

    # Stub the importer to avoid HTTP calls
    Trading212Item::Importer.any_instance.stubs(:import).returns({ success: true })

    # Run sync without raising
    @syncer.perform_sync(sync)

    # Sync ran without raising; verify stats were collected
    stats = sync.reload.sync_stats
    assert stats.present?
  end

  test "perform_sync sets pending_account_setup when accounts are unlinked" do
    sync = @item.syncs.create!

    Trading212Item::Importer.any_instance.expects(:import).returns({ success: true })

    @syncer.perform_sync(sync)

    assert @item.reload.pending_account_setup?
  end

  # === perform_sync (error handling) ===

  test "perform_sync records error stats on generic failure" do
    sync = @item.syncs.create!
    Trading212Item::Importer.any_instance.expects(:import).raises(StandardError.new("Boom"))

    assert_raises(StandardError) do
      @syncer.perform_sync(sync)
    end

    stats = sync.reload.sync_stats
    assert stats["total_errors"] >= 1
  end

  # === perform_post_sync ===

  test "perform_post_sync is a no-op" do
    assert_nil @syncer.perform_post_sync
  end
end
