require "test_helper"

class TradeRepublicReloginPollJobTest < ActiveJob::TestCase
  include TradeRepublicSessionTestHelper
  include ActionMailer::TestHelper

  setup do
    @old_session = trade_republic_session_blob(expires_at: 40.minutes.from_now)
    @item = trade_republic_items(:configured_item)
    @item.update!(session_blob: @old_session, pin: "1234", pending_login_state: "pending-b64", auto_login_time: "07:30")
    @token = @item.reload.auto_login_token
    clear_enqueued_jobs
    @expires = @item.session_expires_at.to_i
    @provider = mock("provider")
    @item.stubs(:trade_republic_provider).returns(@provider)
    @new_session = trade_republic_session_blob(expires_at: 24.hours.from_now)
  end

  test "replaces the session once the push is approved and syncs" do
    @provider.expects(:complete_login).with(pending_login_b64: "pending-b64").returns(confirmed)
    @item.expects(:sync_later).once

    perform

    @item.reload
    assert_equal @new_session, @item.session_blob
    assert_nil @item.pending_login_state
    assert_predicate @item, :good?
    assert_equal "DE123", @item.brokerage_account_id
  end

  test "keeps polling while the approval is pending, without hammering" do
    @provider.expects(:complete_login).returns(waiting)

    assert_enqueued_with(job: TradeRepublicReloginPollJob) { perform }

    interval = TradeRepublicReloginPollJob::POLL_INTERVAL
    assert_operator interval, :>=, 5.seconds
    assert_equal @old_session, @item.reload.session_blob
  end

  test "retries 30 minutes later when the user does not approve in time and keeps the old session" do
    @provider.expects(:complete_login).raises(Provider::TradeRepublicClient::LoginExpired)

    freeze_time do
      assert_enqueued_with(job: TradeRepublicReloginJob, at: 30.minutes.from_now, args: [ @item, { token: @token, attempt: 2, window_ends_at: @expires, session_stamp: @expires } ]) do
        perform
      end
    end

    @item.reload
    assert_nil @item.pending_login_state
    assert_equal @old_session, @item.session_blob
    assert_predicate @item, :good?
    assert_no_enqueued_emails
  end

  test "tells the admins once when the last attempt is not approved" do
    @provider.expects(:complete_login).raises(Provider::TradeRepublicClient::LoginExpired)

    assert_enqueued_emails(1) do
      TradeRepublicReloginPollJob.perform_now(
        @item, pending_digest: Digest::SHA256.hexdigest("pending-b64"),
        token: @token, attempt: TradeRepublicReloginJob::MAX_ATTEMPTS, window_ends_at: @expires, session_stamp: @expires
      )
    end
  end

  test "a poll of a replaced schedule does not reach the provider and does nothing" do
    @item.update!(auto_login_time: "09:00")
    @provider.expects(:complete_login).never

    assert_no_enqueued_jobs(only: [ TradeRepublicReloginJob, TradeRepublicReloginPollJob ]) { perform }
    assert_no_enqueued_emails
    assert_equal @old_session, @item.reload.session_blob
  end

  test "a poll of a replaced schedule clears the pending login it belongs to, so the next day can log in" do
    @item.update!(auto_login_time: "09:00")
    @provider.expects(:complete_login).never

    perform

    assert_nil @item.reload.pending_login_state
  end

  test "a poll of a switched-off schedule clears the pending login it belongs to" do
    @item.update!(auto_login_time: nil)

    perform

    assert_nil @item.reload.pending_login_state
  end

  test "a poll of a replaced schedule leaves a manual login alone" do
    @item.update!(auto_login_time: "09:00", pending_login_state: "manual-b64")

    perform

    assert_equal "manual-b64", @item.reload.pending_login_state
  end

  test "a poll of a cycle that a new session ended clears the pending login it belongs to" do
    @item.update!(session_blob: @new_session)
    @provider.expects(:complete_login).never

    perform

    assert_nil @item.reload.pending_login_state
  end

  test "auto login switched off while the poll waits for the provider keeps the old session" do
    @provider.expects(:complete_login).with { TradeRepublicItem.find(@item.id).update!(auto_login_time: nil) }.returns(confirmed)
    @item.expects(:sync_later).never

    perform

    assert_equal @old_session, @item.reload.session_blob
  end

  test "a browser poll that already consumed the expiry still counts as a failed attempt" do
    @item.update!(pending_login_state: nil)
    @provider.expects(:complete_login).never

    freeze_time do
      assert_enqueued_with(job: TradeRepublicReloginJob, at: 30.minutes.from_now, args: [ @item, { token: @token, attempt: 2, window_ends_at: @expires, session_stamp: @expires } ]) do
        perform
      end
    end
  end

  test "sends no mail when the login succeeds" do
    @provider.expects(:complete_login).returns(confirmed)
    @item.stubs(:sync_later)

    assert_no_enqueued_emails { perform }
  end

  test "stops on rate limiting without retrying and tells the admins" do
    @provider.expects(:complete_login).raises(Provider::TradeRepublicClient::RateLimited.new("slow down"))

    assert_enqueued_emails(1) do
      assert_no_enqueued_jobs(only: [ TradeRepublicReloginJob, TradeRepublicReloginPollJob ]) { perform }
    end

    assert_nil @item.reload.pending_login_state
    assert_equal @old_session, @item.session_blob
  end

  test "stops on any other provider error and tells the admins" do
    @provider.expects(:complete_login).raises(Provider::TradeRepublicClient::MalformedResponse, "bad")

    assert_enqueued_emails(1) do
      assert_no_enqueued_jobs(only: [ TradeRepublicReloginJob, TradeRepublicReloginPollJob ]) { perform }
    end

    assert_nil @item.reload.pending_login_state
  end

  test "does nothing when the pending login was replaced by a manual login" do
    @item.update!(pending_login_state: "manual-b64")
    @provider.expects(:complete_login).never

    perform

    assert_equal "manual-b64", @item.reload.pending_login_state
    assert_equal @old_session, @item.session_blob
  end

  test "does nothing once a manual login finished meanwhile" do
    @item.update!(pending_login_state: nil, session_blob: @new_session)
    @provider.expects(:complete_login).never

    perform

    assert_equal @new_session, @item.reload.session_blob
  end

  test "a manual login finishing during the poll wins" do
    @provider.expects(:complete_login).with { TradeRepublicItem.find(@item.id).update!(pending_login_state: "manual-b64") }.returns(confirmed)
    @item.expects(:sync_later).never

    perform

    assert_equal @old_session, @item.reload.session_blob
    assert_equal "manual-b64", @item.pending_login_state
  end

  test "discards the connection when the account belongs to another one" do
    other = trade_republic_items(:requires_update_item)
    other.update!(brokerage_account_id: "DE123")
    @provider.expects(:complete_login).returns(confirmed)
    @item.expects(:sync_later).never

    perform

    @item.reload
    assert_predicate @item, :requires_update?
    assert_nil @item.session_blob
    assert_nil @item.pending_login_state
  end

  private

    def perform
      TradeRepublicReloginPollJob.perform_now(
        @item,
        pending_digest: Digest::SHA256.hexdigest("pending-b64"),
        token: @token,
        attempt: 1,
        window_ends_at: @expires,
        session_stamp: @expires
      )
    end

    def confirmed
      Provider::TradeRepublicClient::Result.new(data: {
        "status" => "ok",
        "session_txt" => @new_session,
        "account" => { "brokerage_account_id" => "DE123", "currency" => "EUR" }
      })
    end

    def waiting
      Provider::TradeRepublicClient::Result.new(data: { "status" => "pending", "pending_login_b64" => "pending-b64" })
    end
end
