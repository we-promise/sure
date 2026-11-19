require "test_helper"

class TradeRepublicPreExpirySyncJobTest < ActiveJob::TestCase
  include TradeRepublicSessionTestHelper

  setup do
    @item = trade_republic_items(:configured_item)
    @item.update!(session_blob: trade_republic_session_blob(expires_at: 30.minutes.from_now))
  end

  test "syncs while the session it was planned for is still valid" do
    @item.expects(:sync_later).once

    TradeRepublicPreExpirySyncJob.perform_now(@item, session_expires_at: @item.session_expires_at.to_i)
  end

  test "leaves the sync to the newer login once the session was replaced" do
    @item.expects(:sync_later).never

    TradeRepublicPreExpirySyncJob.perform_now(@item, session_expires_at: 1.hour.ago.to_i)
  end

  test "does not sync a connection that needs a new login" do
    @item.update!(status: :requires_update)
    @item.expects(:sync_later).never

    TradeRepublicPreExpirySyncJob.perform_now(@item, session_expires_at: @item.session_expires_at.to_i)
  end

  test "plans nothing when the sync time has already passed" do
    assert_no_enqueued_jobs only: TradeRepublicPreExpirySyncJob do
      TradeRepublicPreExpirySyncJob.schedule_for(@item)
    end
  end
end
