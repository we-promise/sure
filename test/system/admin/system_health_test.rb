require "application_system_test_case"

class Admin::SystemHealthTest < ApplicationSystemTestCase
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
