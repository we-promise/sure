require "test_helper"

class EnableBankingItem::SyncerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

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

  test "a throttled import fails honestly and schedules a retry without losing authorization" do
    @item.update!(session_expires_at: 1.day.from_now)
    error = Provider::EnableBanking::EnableBankingError.new("limited", :rate_limited, http_status: 429)
    @item.expects(:import_latest_enable_banking_data).once.raises(error)
    sync = Sync.create!(syncable: @item)
    assert_enqueued_with(job: EnableBankingSyncRetryJob) do
      sync.perform
    end
    assert sync.reload.failed?
    assert_nil sync.completed_at
    assert @item.reload.sync_retry_pending?
    assert @item.session_valid?
    assert_nil @item.last_synced_at
  end

  test "a permanent failure during retry clears the waiting state" do
    @item.update!(session_expires_at: 1.day.from_now, sync_retry_reason: "temporary_error", sync_retry_count: 1)
    @item.expects(:import_latest_enable_banking_data).returns(success: false, error: "Invalid bank data")
    sync = Sync.create!(syncable: @item)
    sync.perform
    assert sync.reload.failed?
    assert_not @item.reload.sync_retry_pending?
    assert_equal 0, @item.sync_retry_count
  end
end
