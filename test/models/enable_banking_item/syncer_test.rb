require "test_helper"

class EnableBankingItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = EnableBankingItem.create!(
      family: families(:dylan_family),
      name: "Test",
      country_code: "DE",
      application_id: "app",
      client_certificate: "cert",
      session_id: "sess",
      session_expires_at: 1.day.ago, # expired
      status: :good
    )
    @syncer = EnableBankingItem::Syncer.new(@item)
  end

  test "expired session marks requires_update and finishes gracefully without raising" do
    sync = Sync.create!(syncable: @item)

    assert_nothing_raised do
      @syncer.perform_sync(sync)
    end

    assert @item.reload.requires_update?

    stats = sync.reload.sync_stats || {}
    assert_equal 0, (stats["total_errors"] || 0),
      "Expired session should be a graceful reconnect state, not a red sync error"
  end

  test "ignored accounts do not leave the connection waiting for setup" do
    @item.update!(session_expires_at: 1.day.from_now)
    @item.enable_banking_accounts.create!(name: "Theirs", uid: "hash_theirs", currency: "EUR").ignore!
    @item.stubs(:import_latest_enable_banking_data).returns(success: true)
    sync = Sync.create!(syncable: @item)

    @syncer.perform_sync(sync)

    assert_not @item.reload.pending_account_setup?
    assert_equal 0, sync.reload.sync_stats["unlinked_accounts"]
  end

  test "a truncated full-history fetch is recorded as a data warning on the sync" do
    @item.update!(session_expires_at: 1.day.from_now)
    @item.stubs(:import_latest_enable_banking_data).returns(success: true, transactions_truncated: 1)
    sync = Sync.create!(syncable: @item)

    @syncer.perform_sync(sync)

    stats = sync.reload.sync_stats
    assert_equal 1, stats["data_warnings"]
    assert_match(/older transactions may be missing/, stats["data_quality_details"].first["message"])
    assert_equal 0, stats["total_errors"]
  end

  test "a truncated full-history fetch is recorded even when another account fails" do
    @item.update!(session_expires_at: 1.day.from_now)
    @item.stubs(:import_latest_enable_banking_data).returns(success: false, transactions_failed: 1, transactions_truncated: 1)
    sync = Sync.create!(syncable: @item)

    assert_raises(StandardError) { @syncer.perform_sync(sync) }

    assert_equal 1, sync.reload.sync_stats["data_warnings"]
  end
end
