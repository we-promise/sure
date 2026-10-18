require "test_helper"

class EnableBankingItem::SyncSchedulingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @item = EnableBankingItem.create!(family: families(:dylan_family), name: "Bank", country_code: "IT",
                                    application_id: "app", client_certificate: "cert", session_id: "session",
                                    session_expires_at: 1.day.from_now)
  end

  test "a persisted cooldown blocks duplicate requests and worker reservations" do
    @item.reserve_sync_slot!
    another_instance = EnableBankingItem.find(@item.id)
    assert_no_enqueued_jobs { assert_nil another_instance.sync_later }
    assert_raises(EnableBankingItem::SyncScheduling::SyncDeferredError) { another_instance.reserve_sync_slot! }
    travel 16.minutes do
      assert_enqueued_with(job: SyncJob) { another_instance.sync_later }
    end
  end

  test "rate limits schedule a durable retry and respect a longer Retry-After" do
    error = Provider::EnableBanking::EnableBankingError.new("limited", :rate_limited, retry_after: 9.hours, http_status: 429)
    assert_enqueued_with(job: EnableBankingSyncRetryJob) { @item.schedule_sync_retry!(error) }
    assert_in_delta 9.hours.from_now, @item.reload.next_sync_at, 2
    assert @item.sync_retry_pending?
    assert @item.session_valid?
    assert_equal 1, @item.sync_retry_count
  end

  test "fallback delays increase and obsolete retry jobs do nothing" do
    error = Provider::EnableBanking::EnableBankingError.new("limited", :rate_limited)
    @item.schedule_sync_retry!(error)
    old_retry_at = @item.next_sync_at.iso8601(6)
    assert_in_delta 6.hours.from_now, @item.next_sync_at, 2
    @item.schedule_sync_retry!(error)
    assert_in_delta 12.hours.from_now, @item.next_sync_at, 2
    assert_no_enqueued_jobs { EnableBankingSyncRetryJob.perform_now(@item, old_retry_at) }
  end

  test "retry job queues one sync when due and ignores a removed connection" do
    @item.update!(next_sync_at: 1.second.ago, sync_retry_reason: "rate_limited")
    assert_enqueued_with(job: SyncJob) do
      EnableBankingSyncRetryJob.perform_now(@item, @item.next_sync_at.iso8601(6))
    end
    @item.update!(scheduled_for_deletion: true)
    assert_no_enqueued_jobs { EnableBankingSyncRetryJob.perform_now(@item, @item.next_sync_at.iso8601(6)) }
  end

  test "temporary errors have bounded retries and an interrupted retry remains recoverable" do
    error = Provider::EnableBanking::EnableBankingError.new("timeout", :timeout)
    3.times { assert @item.schedule_sync_retry!(error) }
    assert_no_enqueued_jobs { assert_not @item.schedule_sync_retry!(error) }
    assert_not @item.sync_retry_pending?
    @item.update!(next_sync_at: 1.second.ago, sync_retry_reason: "temporary_error")
    @item.reserve_sync_slot!
    assert @item.reload.sync_retry_pending?
    travel 16.minutes do
      assert_enqueued_with(job: SyncJob) { SyncHourlyJob.perform_now }
    end
  end

  test "the existing hourly sweep recovers retry intent after an enqueue failure" do
    configured_job = mock("retry queue")
    configured_job.expects(:perform_later).raises(ActiveJob::EnqueueError.new("unavailable"))
    EnableBankingSyncRetryJob.expects(:set).returns(configured_job)
    error = Provider::EnableBanking::EnableBankingError.new("limited", :rate_limited)
    assert @item.schedule_sync_retry!(error)
    assert @item.reload.sync_retry_pending?

    travel 7.hours do
      assert_enqueued_with(job: SyncJob) { SyncHourlyJob.perform_now }
    end
  end

  test "an early retry job is rescheduled without making a bank request" do
    @item.update!(next_sync_at: 1.minute.from_now, sync_retry_reason: "rate_limited")
    assert_enqueued_with(job: EnableBankingSyncRetryJob, at: @item.next_sync_at) do
      EnableBankingSyncRetryJob.perform_now(@item, @item.next_sync_at.iso8601(6))
    end
  end
end
