require "test_helper"

class PushNotificationTestTest < ActiveJob::TestCase
  setup do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Apns::Client.stubs(:configured?).returns(true)
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)
    @user = users(:sure_support_staff)
    @subscription = @user.push_subscriptions.create!(
      token: "ab" * 32, environment: "sandbox", platform: "ios", last_registered_at: Time.current
    )
    @test = PushNotificationTest.new(@user)
  end

  test "queues only this super admin's recent devices and limits repeated clicks" do
    users(:family_admin).push_subscriptions.create!(
      token: "cd" * 32, environment: "production", platform: "ios", last_registered_at: Time.current
    )
    @user.push_subscriptions.create!(
      token: "ef" * 32, environment: "production", platform: "ios", last_registered_at: 91.days.ago
    )
    Apns::Client.expects(:new).never

    assert_enqueued_jobs 1, only: DeliverTestPushNotificationJob do
      assert_equal :queued, @test.request!
      assert_equal :cooldown, @test.request!
    end
    assert_enqueued_with(job: DeliverTestPushNotificationJob, args: [ {
      user_id: @user.id, request_id: @test.latest[:id], push_subscription_id: @subscription.id
    } ])
    assert_equal [ "queued" ], @test.results(@test.latest).pluck(:status)
  end

  test "does not require an insight or preview opt in" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    @test.request!
    client = mock
    Apns::Client.expects(:new).with(environment: "sandbox").returns(client)
    client.expects(:deliver_test).with(
      token: @subscription.token, title: "Sure test notification",
      body: "This is a test push notification for your Sure account.", request_id: @test.latest[:id]
    ).returns(stub(ok?: true))

    assert_no_difference "Insight.count" do
      deliver
      deliver # An ordinary queue replay does not send a second alert.
    end
    assert_equal "accepted", result_status
  end

  test "localizes the test alert for the initiating user" do
    @user.update!(locale: "de")
    @test.request!
    Apns::Client.any_instance.expects(:deliver_test).with(
      token: @subscription.token, title: "Sure-Testbenachrichtigung",
      body: "Dies ist eine Testbenachrichtigung für dein Sure-Konto.", request_id: @test.latest[:id]
    ).returns(stub(ok?: true))
    deliver
    assert_equal "accepted", result_status
  end

  test "skips a device removed after queueing" do
    @test.request!
    @subscription.destroy!
    Apns::Client.expects(:new).never
    deliver
    assert_equal "skipped", result_status
  end

  test "skips a device transferred to another user after queueing" do
    @test.request!
    @subscription.update!(user: users(:family_admin))
    Apns::Client.expects(:new).never
    deliver
    assert_equal "skipped", result_status
  end

  test "skips a stale registration after queueing" do
    @test.request!
    @subscription.update!(last_registered_at: 91.days.ago)
    Apns::Client.expects(:new).never
    deliver
    assert_equal "skipped", result_status
  end

  test "role or active status changes prevent delivery" do
    @test.request!
    @user.update_columns(role: "admin")
    Apns::Client.expects(:new).never
    deliver
    assert_equal "skipped", result_status
    @user.update_columns(role: "super_admin", active: false)
    assert_equal :ineligible, @test.disabled_reason
  end

  test "host mode is rechecked by the worker and at request time" do
    @test.request!
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    assert_equal :hosted_only, @test.request!
    Apns::Client.expects(:new).never
    deliver
    assert_equal "skipped", result_status
  end

  test "kill switch disables new and queued test notifications" do
    @test.request!
    ClimateControl.modify("APNS_ENABLED" => "false") do
      assert_equal :disabled, @test.request!
      Apns::Client.expects(:new).never
      deliver
      assert_equal "skipped", result_status
    end
  end

  test "unconfigured APNs and missing devices cannot enqueue" do
    Apns::Client.stubs(:configured?).returns(false)
    assert_no_enqueued_jobs do
      assert_equal :not_configured, @test.request!
      @subscription.destroy!
      assert_equal :no_devices, @test.request!
    end
  end

  test "expired requests and forged subscriptions cannot send" do
    @test.request!
    Apns::Client.expects(:new).never
    @test.deliver(request_id: SecureRandom.uuid, push_subscription_id: @subscription.id)
    @test.deliver(request_id: @test.latest[:id], push_subscription_id: SecureRandom.uuid)
    travel 16.minutes do
      assert_equal "expired", result_status
      deliver
      assert_equal "skipped", result_status
    end
  end

  test "a cache failure does not enqueue a request the worker cannot find" do
    @cache.stubs(:write).returns(false)
    assert_no_enqueued_jobs do
      assert_equal :storage_unavailable, @test.request!
    end
  end

  test "records enqueue failure per device" do
    [ ActiveJob::EnqueueError, Redis::BaseError, RedisClient::CannotConnectError ].each do |error_class|
      @cache.clear
      DeliverTestPushNotificationJob.stubs(:perform_later).raises(error_class)
      assert_equal :enqueue_failed, @test.request!
      assert_equal "enqueue_failed", result_status
    end
  end

  test "results are isolated between users and devices" do
    second = @user.push_subscriptions.create!(
      token: "cd" * 32, environment: "production", platform: "ios", last_registered_at: Time.current
    )
    @test.request!
    @test.record(@test.latest[:id], @subscription.id, :accepted)
    @test.record(@test.latest[:id], second.id, :failed)
    assert_equal %w[accepted failed], @test.results(@test.latest).pluck(:status).sort
    assert_nil PushNotificationTest.new(users(:family_admin)).latest
  end

  test "transient errors retry without reporting success" do
    @test.request!
    Apns::Client.any_instance.stubs(:deliver_test).returns(stub(ok?: false, status: "503"))
    assert_enqueued_with(job: DeliverTestPushNotificationJob) do
      deliver
    end
    assert_equal "retrying", result_status
  end

  private
    def deliver
      DeliverTestPushNotificationJob.perform_now(
        user_id: @user.id, request_id: @test.latest[:id], push_subscription_id: @subscription.id
      )
    end

    def result_status
      @test.results(@test.latest).first[:status]
    end
end
