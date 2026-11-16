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
end
