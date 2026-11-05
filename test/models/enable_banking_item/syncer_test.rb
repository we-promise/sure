require "test_helper"

class EnableBankingItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = EnableBankingItem.create!(
      family: families(:dylan_family),
      name: "Test",
      country_code: "DE",
      application_id: "app",
      client_certificate: "cert", sync_start_date: 3.months.ago.to_date,
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

  test "truncated initial history still processes the stored pages before failing the sync" do
    @item.update!(session_expires_at: 1.day.from_now)
    enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @item, name: "Checking", uid: "hash_truncated", account_id: "uuid-truncated", currency: "EUR"
    )
    AccountProvider.create!(account: accounts(:depository), provider: enable_banking_account)
    sync = Sync.create!(syncable: @item)

    error = I18n.t("enable_banking_items.errors.history_truncated")
    @item.stubs(:import_latest_enable_banking_data).returns(
      success: false, accounts_failed: 0, transactions_failed: 0, history_truncated: 1, error: error
    )
    @item.expects(:process_accounts).once
    @item.expects(:schedule_account_syncs).once

    raised = assert_raises(StandardError) { @syncer.perform_sync(sync) }
    assert_equal error, raised.message
  end

  test "other import failures still stop before processing" do
    @item.update!(session_expires_at: 1.day.from_now)
    sync = Sync.create!(syncable: @item)
    @item.stubs(:import_latest_enable_banking_data).returns(
      success: false, accounts_failed: 0, transactions_failed: 1, history_truncated: 1, error: "boom"
    )
    @item.expects(:process_accounts).never

    assert_raises(StandardError) { @syncer.perform_sync(sync) }
  end
end
