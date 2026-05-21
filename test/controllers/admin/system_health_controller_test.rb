require "test_helper"

class Admin::SystemHealthControllerTest < ActionDispatch::IntegrationTest
  test "super admin can view the system health page" do
    sign_in users(:sure_support_staff)
    SidekiqHealth.any_instance.stubs(:healthy?).returns(true)
    SidekiqHealth.any_instance.stubs(:processes_count).returns(1)
    SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(Time.current)
    SidekiqHealth.any_instance.stubs(:max_queue_latency).returns(0.0)
    SidekiqHealth.any_instance.stubs(:enqueued_count).returns(0)
    SidekiqHealth.any_instance.stubs(:retry_count).returns(0)
    SidekiqHealth.any_instance.stubs(:failed_count).returns(0)
    SidekiqHealth.any_instance.stubs(:processed_count).returns(42)
    SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([ [ "default", 0, 0.0 ] ])

    get admin_system_health_url

    assert_response :success
    assert_match(/Sidekiq status/, response.body)
    assert_match(/Healthy/, response.body)
  end

  test "renders degraded state with reason when Sidekiq is unhealthy" do
    sign_in users(:sure_support_staff)
    SidekiqHealth.any_instance.stubs(:healthy?).returns(false)
    SidekiqHealth.any_instance.stubs(:reason).returns(:no_worker_processes)
    SidekiqHealth.any_instance.stubs(:processes_count).returns(0)
    SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(nil)
    SidekiqHealth.any_instance.stubs(:max_queue_latency).returns(0.0)
    SidekiqHealth.any_instance.stubs(:enqueued_count).returns(7)
    SidekiqHealth.any_instance.stubs(:retry_count).returns(0)
    SidekiqHealth.any_instance.stubs(:failed_count).returns(0)
    SidekiqHealth.any_instance.stubs(:processed_count).returns(0)
    SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([])

    get admin_system_health_url

    assert_response :success
    assert_match(/Degraded/, response.body)
    assert_match(/No Sidekiq worker process is connected/, response.body)
  end

  test "non super admin is redirected away" do
    sign_in users(:family_admin)

    get admin_system_health_url

    assert_redirected_to root_path
  end

  test "unauthenticated user is redirected to sign in" do
    get admin_system_health_url

    assert_redirected_to new_session_path
  end
end
