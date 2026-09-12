require "application_system_test_case"

class Admin::SystemHealthTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    sign_in users(:sure_support_staff)
    Setting.stubs(:llm_provider).returns("openai")
    Setting.stubs(:openai_access_token).returns(nil)
    Setting.stubs(:openai_uri_base).returns(nil)
    Setting.stubs(:openai_model).returns(nil)
    stub_healthy_sidekiq
    AiHealth::Probe.any_instance.stubs(:llm).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:function_calling).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:pdf_text_extraction).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:pdf_vision_processing).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:openai_vector_store).returns(probe_result(:passing))
  end

  test "selecting AI status runs live probes" do
    ClimateControl.modify(
      "OPENAI_ACCESS_TOKEN" => "test-token",
      "OPENAI_URI_BASE" => nil,
      "OPENAI_MODEL" => nil,
      "VECTOR_STORE_PROVIDER" => nil
    ) do
      visit admin_system_health_path

      click_button "AI status"

      assert_current_path admin_system_health_path(tab: "ai")
      assert_selector "button[role='tab'][aria-selected='true']", text: "AI status"
      assert_text "Live check passed"
      assert_text "Live tool call succeeded"
      assert_text "PDF text-extraction path"
      assert_text "PDF vision/native path"
      assert_text "Synthetic PDF check passed", count: 2
      assert_text "Live checks passed"
    end
  end

  test "hosted super admin enables the test button by registering an iOS device" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Apns::Client.stubs(:configured?).returns(true)
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    visit admin_system_health_path
    assert_selector "button[role='tab']", count: 2
    assert_selector "button[role='tab'][aria-selected='true']", text: "Background jobs"
    assert_selector "h2", text: "Push notifications"
    assert_button "Send test push notification", disabled: true
    assert_text "Enable push notifications in the Sure iOS app"

    user = users(:sure_support_staff)
    user.push_subscriptions.create!(
      token: "ab" * 32, environment: "sandbox", platform: "ios", last_registered_at: Time.current
    )
    visit admin_system_health_path(tab: "background_jobs")
    assert_button "Send test push notification", disabled: false
    Apns::Client.expects(:new).never
    assert_enqueued_jobs 1, only: DeliverTestPushNotificationJob do
      click_button "Send test push notification"
      assert_text "Test notification queued"
    end
    assert_text "Queued"
    assert_button "Send test push notification", disabled: true
    Apns::Client.unstub(:new)
    Apns::Client.any_instance.stubs(:deliver_test).returns(stub(ok?: true))
    perform_enqueued_jobs only: DeliverTestPushNotificationJob
    travel 31.seconds do
      visit admin_system_health_path(tab: "background_jobs")
      assert_text "Latest test requested at"
      assert_text "Accepted by APNs"
      assert_button "Send test push notification", disabled: false
      page.save_screenshot(Rails.root.join("tmp", "system-health-background-push-notifications.png"))
    end
  end

  private
    def probe_result(status)
      AiHealth::Probe::Result.new(
        status: status,
        checked_at: Time.current,
        failure_code: nil,
        http_status: nil
      )
    end

    def stub_healthy_sidekiq
      SidekiqHealth.any_instance.stubs(:healthy?).returns(true)
      SidekiqHealth.any_instance.stubs(:processes_count).returns(1)
      SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(Time.current)
      SidekiqHealth.any_instance.stubs(:max_queue_latency).returns(0.0)
      SidekiqHealth.any_instance.stubs(:enqueued_count).returns(0)
      SidekiqHealth.any_instance.stubs(:retry_count).returns(0)
      SidekiqHealth.any_instance.stubs(:failed_count).returns(0)
      SidekiqHealth.any_instance.stubs(:processed_count).returns(42)
      SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([ [ "default", 0, 0.0 ] ])
    end
end
