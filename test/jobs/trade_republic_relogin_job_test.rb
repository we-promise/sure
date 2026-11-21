require "test_helper"

class TradeRepublicReloginJobTest < ActiveJob::TestCase
  include TradeRepublicSessionTestHelper
  include ActionMailer::TestHelper

  setup do
    families(:dylan_family).update!(timezone: "Europe/Berlin")
    @item = trade_republic_items(:configured_item)
    @item.update!(session_blob: trade_republic_session_blob(expires_at: 5.hours.from_now), pin: "1234", auto_login_time: "07:30")
    @token = @item.reload.auto_login_token
    clear_enqueued_jobs
    @provider = mock("provider")
    @item.stubs(:trade_republic_provider).returns(@provider)
  end

  test "plans the next login at the set time of day in the family's zone" do
    travel_to Time.utc(2026, 11, 17, 5, 0) do
      assert_enqueued_with(job: TradeRepublicReloginJob, at: Time.utc(2026, 11, 17, 6, 30)) do
        TradeRepublicReloginJob.schedule_for(@item)
      end
    end

    assert_predicate @item.reload.auto_login_token, :present?
  end

  test "plans nothing while auto login is off" do
    @item.update!(auto_login_time: nil)

    assert_no_enqueued_jobs only: TradeRepublicReloginJob do
      TradeRepublicReloginJob.schedule_for(@item)
    end
    assert_nil @item.reload.auto_login_token
  end

  test "starts a push login with the stored PIN and keeps the old session and status while it is pending" do
    old_session = @item.session_blob
    @provider.expects(:initiate_login).returns(initiated)

    assert_enqueued_with(job: TradeRepublicReloginPollJob) { perform }

    @item.reload
    assert_equal "pending-b64", @item.pending_login_state
    assert_equal old_session, @item.session_blob
    assert_predicate @item, :good?
    assert_predicate @item, :ready_for_sync?
  end

  test "plans the next day's login with the same schedule token" do
    @provider.stubs(:initiate_login).returns(initiated)
    @item.update_columns(auto_login_planned_for: Time.utc(2026, 11, 17, 6, 30))

    travel_to Time.utc(2026, 11, 17, 6, 30) do
      assert_enqueued_with(job: TradeRepublicReloginJob, at: Time.utc(2026, 11, 18, 6, 30)) { perform }
    end

    assert_equal @token, @item.reload.auto_login_token
  end

  test "a retried first attempt does not plan the next day a second time" do
    @provider.stubs(:initiate_login).returns(initiated)
    @item.update_columns(auto_login_planned_for: Time.utc(2026, 11, 17, 6, 30))

    travel_to Time.utc(2026, 11, 17, 6, 30) do
      assert_enqueued_jobs 1, only: TradeRepublicReloginJob do
        perform
        perform
      end
    end
  end

  test "a next day that could not be queued does not stay claimed" do
    queue = mock("queue")
    queue.expects(:perform_later).raises(RuntimeError, "queue down")
    TradeRepublicReloginJob.expects(:set).returns(queue)

    assert_raises(RuntimeError) { TradeRepublicReloginJob.schedule_for(@item) }

    assert_nil @item.reload.auto_login_planned_for
    assert_nil @item.auto_login_token
  end

  test "a schedule that could not be queued is repaired by saving the item again" do
    TradeRepublicReloginJob.stubs(:set).raises(RuntimeError, "queue down")
    assert_raises(RuntimeError) { TradeRepublicReloginJob.schedule_for(@item) }
    TradeRepublicReloginJob.unstub(:set)

    @item.reload
    assert_enqueued_jobs 1, only: TradeRepublicReloginJob do
      @item.update!(name: "renamed")
    end
    assert_predicate @item.reload.auto_login_token, :present?
  end

  test "saving the item again does not queue a second chain while one exists" do
    assert_no_enqueued_jobs only: TradeRepublicReloginJob do
      @item.update!(name: "renamed")
    end
    assert_equal @token, @item.reload.auto_login_token
  end

  test "the schedule follows the stored time, not the time the saving instance holds" do
    stale = TradeRepublicItem.find(@item.id)
    stale.auto_login_time = nil

    assert_enqueued_jobs 1, only: TradeRepublicReloginJob do
      TradeRepublicReloginJob.schedule_for(stale)
    end
    assert_predicate @item.reload.auto_login_token, :present?
  end

  test "a stale instance with the time set does not schedule what the stored row switched off" do
    @item.update_columns(auto_login_time: nil, auto_login_token: nil)
    stale = TradeRepublicItem.find(@item.id)
    stale.auto_login_time = "07:30"

    assert_no_enqueued_jobs only: TradeRepublicReloginJob do
      TradeRepublicReloginJob.schedule_for(stale)
    end
    assert_nil @item.reload.auto_login_token
  end

  test "a first poll that could not be queued clears the pending login of this attempt" do
    @provider.stubs(:initiate_login).returns(initiated)
    queue = mock("queue")
    queue.expects(:perform_later).raises(RuntimeError, "queue down")
    TradeRepublicReloginPollJob.expects(:set).returns(queue)

    assert_raises(RuntimeError) { perform }

    assert_nil @item.reload.pending_login_state
  end

  test "a first poll that could not be queued leaves a login the user started meanwhile alone" do
    @provider.stubs(:initiate_login).returns(initiated)
    queue = mock("queue")
    queue.expects(:perform_later).with { TradeRepublicItem.find(@item.id).update!(pending_login_state: "manual-b64") }.raises(RuntimeError, "queue down")
    TradeRepublicReloginPollJob.expects(:set).returns(queue)

    assert_raises(RuntimeError) { perform }

    assert_equal "manual-b64", @item.reload.pending_login_state
  end

  test "the next day is planned again once the setting changed" do
    travel_to Time.utc(2026, 11, 17, 6, 30) do
      TradeRepublicReloginJob.schedule_for(@item)
      assert_enqueued_jobs 1, only: TradeRepublicReloginJob
    end
  end

  test "does not put the PIN or the pending state into queued jobs" do
    @provider.expects(:initiate_login).returns(initiated)

    perform

    arguments = enqueued_jobs.map { |job| job.fetch("arguments") }.to_s
    assert_not_includes arguments, "1234"
    assert_not_includes arguments, "pending-b64"
  end

  test "does nothing for a job planned before the setting changed" do
    @provider.expects(:initiate_login).never

    TradeRepublicReloginJob.perform_now(@item, token: "stale-token", attempt: 1)

    assert_nil @item.reload.pending_login_state
    assert_no_enqueued_jobs only: [ TradeRepublicReloginJob, TradeRepublicReloginPollJob ]
    assert_no_enqueued_emails
  end

  test "does nothing once auto login was switched off" do
    @item.update!(auto_login_time: nil)
    @provider.expects(:initiate_login).never

    TradeRepublicReloginJob.perform_now(@item, token: @token, attempt: 1)

    assert_no_enqueued_jobs only: [ TradeRepublicReloginJob, TradeRepublicReloginPollJob ]
    assert_no_enqueued_emails
  end

  test "logs in again with the stored PIN once the old session ended" do
    @item.update_columns(session_expires_at: 1.minute.ago, status: "requires_update")
    @provider.expects(:initiate_login).returns(initiated)

    assert_enqueued_with(job: TradeRepublicReloginPollJob) { perform }

    assert_equal "pending-b64", @item.reload.pending_login_state
  end

  test "a browser login that lapsed unapproved no longer blocks the scheduled one" do
    @item.update!(pending_login_state: pending_blob(expires_at: 10.minutes.ago))
    @provider.expects(:initiate_login).returns(initiated)

    perform

    assert_equal "pending-b64", @item.reload.pending_login_state
  end

  test "a browser login that is still open is left alone" do
    blob = pending_blob(expires_at: 1.minute.from_now)
    @item.update!(pending_login_state: blob)
    @provider.expects(:initiate_login).never

    perform

    assert_equal blob, @item.reload.pending_login_state
  end

  test "a lapsed browser login replaced meanwhile by a new one stays" do
    @item.update!(pending_login_state: pending_blob(expires_at: 10.minutes.ago))
    fresh = pending_blob(expires_at: 1.minute.from_now)
    @item.stubs(:update_if_pending_login_current!).with { TradeRepublicItem.find(@item.id).update!(pending_login_state: fresh) }.returns(false)
    @provider.expects(:initiate_login).never

    perform

    assert_equal fresh, @item.reload.pending_login_state
  end

  test "leaves a login the user started in the browser alone" do
    @item.update!(pending_login_state: "manual-b64")
    @provider.expects(:initiate_login).never

    perform

    assert_equal "manual-b64", @item.reload.pending_login_state
    assert_no_enqueued_emails
  end

  test "an authenticator account cannot log in by itself, so the admins are told once" do
    @provider.expects(:initiate_login).returns(initiated(method: "authenticator"))

    assert_enqueued_emails(1) { perform }

    assert_nil @item.reload.pending_login_state
    assert_predicate @item, :good?
    assert_no_enqueued_jobs only: [ TradeRepublicReloginPollJob ]
  end

  test "a missing PIN is reported to the admins instead of starting a login" do
    @item.update_columns(pin: nil)
    @provider.expects(:initiate_login).never

    assert_enqueued_emails(1) { perform }
  end

  test "a failed start is retried 30 minutes later while the old session still lasts" do
    @provider.expects(:initiate_login).raises(Provider::TradeRepublicClient::Timeout)

    freeze_time do
      assert_enqueued_with(job: TradeRepublicReloginJob, at: 30.minutes.from_now, args: [ @item, { token: @token, attempt: 2, window_ends_at: @item.session_expires_at.to_i, session_stamp: @item.session_expires_at.to_i } ]) do
        perform
      end
    end
    assert_no_enqueued_emails
  end

  test "retries also run when the old session had already ended" do
    @item.update_columns(session_expires_at: 1.minute.ago)
    @provider.expects(:initiate_login).raises(Provider::TradeRepublicClient::Timeout)

    freeze_time do
      assert_enqueued_with(job: TradeRepublicReloginJob, at: 30.minutes.from_now) { perform }
    end
    assert_no_enqueued_emails
  end

  test "stops retrying when the next attempt would fall after the old session ends and tells the admins once" do
    @item.update!(session_blob: trade_republic_session_blob(expires_at: 20.minutes.from_now))
    @provider.expects(:initiate_login).raises(Provider::TradeRepublicClient::Timeout)

    assert_enqueued_emails(1) { retry_attempt(window_ends_at: 20.minutes.from_now.to_i) }

    assert_no_enqueued_jobs only: [ TradeRepublicReloginJob ]
  end

  test "stops after the last allowed attempt and tells the admins once" do
    @provider.expects(:initiate_login).raises(Provider::TradeRepublicClient::Timeout)

    assert_enqueued_emails(1) do
      TradeRepublicReloginJob.perform_now(
        @item, token: @token, attempt: TradeRepublicReloginJob::MAX_ATTEMPTS, window_ends_at: 10.hours.from_now.to_i
      )
    end

    assert_no_enqueued_jobs only: [ TradeRepublicReloginJob ]
  end

  test "rate limiting ends the cycle without another try" do
    @provider.expects(:initiate_login).raises(Provider::TradeRepublicClient::RateLimited.new("slow down"))

    assert_enqueued_emails(1) { retry_attempt }

    assert_no_enqueued_jobs only: [ TradeRepublicReloginJob, TradeRepublicReloginPollJob ]
    assert_predicate @item.reload, :good?
  end

  test "a retry for a replaced schedule does nothing" do
    @provider.expects(:initiate_login).never

    TradeRepublicReloginJob.perform_now(@item, token: "stale-token", attempt: 3, window_ends_at: 1.hour.from_now.to_i)

    assert_no_enqueued_emails
  end

  test "a retry for a cycle that a manual login already refreshed does nothing" do
    stamp = @item.session_expires_at.to_i
    @item.update!(session_blob: trade_republic_session_blob(expires_at: 24.hours.from_now))
    @provider.expects(:initiate_login).never

    assert_no_enqueued_emails do
      TradeRepublicReloginJob.perform_now(@item, token: @token, attempt: 3, window_ends_at: 10.hours.from_now.to_i, session_stamp: stamp)
    end

    assert_no_enqueued_jobs only: [ TradeRepublicReloginJob, TradeRepublicReloginPollJob ]
  end

  test "a retry that only runs after its window ended starts no login and tells the admins" do
    @provider.expects(:initiate_login).never

    assert_enqueued_emails(1) do
      TradeRepublicReloginJob.perform_now(@item, token: @token, attempt: 2, window_ends_at: 1.minute.ago.to_i, session_stamp: @item.session_expires_at.to_i)
    end

    assert_no_enqueued_jobs only: [ TradeRepublicReloginJob, TradeRepublicReloginPollJob ]
  end

  test "auto login switched off while the login starts stores no pending state and polls nothing" do
    @provider.expects(:initiate_login).with { TradeRepublicItem.find(@item.id).update!(auto_login_time: nil) }.returns(initiated)

    perform

    assert_nil @item.reload.pending_login_state
    assert_no_enqueued_jobs only: [ TradeRepublicReloginPollJob ]
  end

  test "never writes the PIN to the debug log" do
    @provider.expects(:initiate_login).raises(Provider::TradeRepublicClient::RateLimited.new("slow down"))

    perform

    assert DebugLogEntry.exists?
    assert_not DebugLogEntry.all.any? { |entry| entry.attributes.values.join(" ").include?("1234") }
  end

  private

    # Attempt 2 and later plan no further day, so what stays unqueued is the retry.
    def retry_attempt(window_ends_at: 10.hours.from_now.to_i)
      TradeRepublicReloginJob.perform_now(@item, token: @token, attempt: 2, window_ends_at: window_ends_at)
    end

    def pending_blob(expires_at:)
      Base64.strict_encode64(JSON.generate("process_id" => "p", "session_blob" => "s", "expires_at" => expires_at.iso8601))
    end

    def perform
      TradeRepublicReloginJob.perform_now(@item, token: @token, attempt: 1)
    end

    def initiated(method: "push")
      Provider::TradeRepublicClient::Result.new(data: {
        "status" => "verification_required",
        "method" => method,
        "pending_login_b64" => "pending-b64"
      })
    end
end
