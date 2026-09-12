require "test_helper"

class Admin::SystemHealthPushNotificationsTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Apns::Client.stubs(:configured?).returns(true)
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @user = users(:sure_support_staff)
    sign_in @user
  end

  test "button is disabled until this super admin registers a device" do
    get admin_system_health_url(tab: "background_jobs")
    assert_response :success
    assert_select "button[role='tab']", count: 2
    assert_select "button[disabled][aria-describedby='push-notification-help']", text: "Send test push notification"
    assert_match "Enable push notifications in the Sure iOS app", response.body

    register_device
    get admin_system_health_url(tab: "background_jobs")
    assert_select "form[action='#{send_test_push_admin_system_health_path}'][method='post'] button:not([disabled])", text: "Send test push notification"
  end

  test "queues for the current account ignoring forged recipient parameters" do
    subscription = register_device
    other_user = users(:family_admin)
    Apns::Client.expects(:new).never
    assert_enqueued_with(job: DeliverTestPushNotificationJob, args: ->(args) {
      args.first[:user_id] == @user.id && args.first[:push_subscription_id] == subscription.id
    }) do
      post send_test_push_admin_system_health_url, params: { user_id: other_user.id, token: "cd" * 32 }
    end
    assert_redirected_to admin_system_health_path(tab: "background_jobs", anchor: "push-notifications")
    assert_match "queued", flash[:notice]
    follow_redirect!
    assert_select "h2", text: "Push notifications"
    assert_match "Latest test requested at", response.body
    assert_select "td", text: "Queued"
    assert_match "does not confirm delivery", response.body
  end

  test "direct post is rejected without an enabled device" do
    assert_no_enqueued_jobs only: DeliverTestPushNotificationJob do
      post send_test_push_admin_system_health_url
    end
    assert_match "Enable push notifications", flash[:alert]
  end

  test "self hosted mode hides the section and rejects the post even with credentials and a device" do
    register_device
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    get admin_system_health_url(tab: "background_jobs")
    assert_response :success
    assert_select "button[role='tab']", text: "Push notifications", count: 0
    assert_select "[data-testid='push-notification-status']", count: 0
    assert_no_enqueued_jobs only: DeliverTestPushNotificationJob do
      post send_test_push_admin_system_health_url
    end
    assert_response :not_found
  end

  test "APNs configuration and kill switch disable the control and direct post" do
    register_device
    Apns::Client.stubs(:configured?).returns(false)
    get admin_system_health_url(tab: "background_jobs")
    assert_select "button[disabled]", text: "Send test push notification"
    assert_match "APNs credentials are not configured", response.body
    assert_no_enqueued_jobs only: DeliverTestPushNotificationJob do
      post send_test_push_admin_system_health_url
    end
    Apns::Client.stubs(:configured?).returns(true)
    ClimateControl.modify("APNS_ENABLED" => "false") do
      get admin_system_health_url(tab: "background_jobs")
      assert_select "button[disabled]", text: "Send test push notification"
      assert_no_enqueued_jobs only: DeliverTestPushNotificationJob do
        post send_test_push_admin_system_health_url
      end
      assert_match "disabled by the operator", flash[:alert]
    end
  end

  test "ordinary admins cannot send diagnostic pushes" do
    sign_in users(:family_admin)
    assert_no_enqueued_jobs only: DeliverTestPushNotificationJob do
      post send_test_push_admin_system_health_url
    end
    assert_redirected_to root_path
  end

  test "unauthenticated requests cannot send diagnostic pushes" do
    reset!
    assert_no_enqueued_jobs only: DeliverTestPushNotificationJob do
      post send_test_push_admin_system_health_url
    end
    assert_redirected_to new_session_path
  end

  test "all system health locales include the notification labels and outcomes" do
    %i[en de fr pt-PT].each do |locale|
      %w[title requested_at send_test messages.no_devices messages.queued statuses.accepted statuses.failed].each do |key|
        assert_kind_of String, I18n.t("admin.system_health.push_notifications.#{key}", locale: locale, time: "2026-09-12", fallback: false, raise: true)
      end
    end
  end

  private
    def register_device
      @user.push_subscriptions.create!(
        token: "ab" * 32, environment: "sandbox", platform: "ios", last_registered_at: Time.current
      )
    end
end
