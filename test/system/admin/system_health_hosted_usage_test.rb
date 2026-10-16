require "application_system_test_case"

class Admin::SystemHealthHostedUsageTest < ApplicationSystemTestCase
  setup do
    sign_in users(:sure_support_staff)
    # Host/deployment combinations are exercised by integration tests. The
    # browser here reaches Capybara's local server, not the production domains.
    HostedUsage.stubs(:available?).returns(true)
    stub_healthy_sidekiq
  end

  test "hosted usage loads when selected and stays read only at desktop and mobile widths" do
    label_screenshot_fixtures
    subscriptions(:trialing).update!(created_at: 2.days.ago, trial_ends_at: 3.days.from_now)
    subscriptions(:active).update!(stripe_id: "sub_supporter")
    families(:dylan_family).update!(stripe_customer_id: "cus_supporter")

    visit admin_system_health_path
    assert_selector "turbo-frame#hosted_usage[loading='lazy']:not([complete])", visible: :all
    click_button "Configuration"
    assert_current_path admin_system_health_path(tab: "configuration")
    assert_selector "[data-testid='configuration-health']"
    assert_selector "turbo-frame#hosted_usage[loading='lazy']:not([complete])", visible: :all
    click_button "Hosted usage"
    assert_no_selector "[data-testid='configuration-health']"

    assert_current_path admin_system_health_path(tab: "hosted_usage")
    assert_selector "button[role='tab'][aria-selected='true']", text: "Hosted usage"
    within "turbo-frame#hosted_usage" do
      assert_text "Recent trial households"
      assert_text(/Retained sign-in sessions/i)
      assert_text "Local supporter status"
      assert_text "not currently online users or visits"
      assert_selector "[data-testid='hosted-usage-trials_expiring_soon_count'] dd", text: "1"
      assert_no_selector "form, button, a[data-turbo-method]"
    end
    page.save_screenshot(Rails.root.join("tmp", "system-health-hosted-usage.png"))

    page.current_window.resize_to(390, 844)
    within "turbo-frame#hosted_usage" do
      assert_selector "[role='region'][aria-label='Recent trial households'][tabindex='0']"
      assert_no_selector "form, button, a[data-turbo-method]"
    end
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "The report must not overflow the mobile page"
    page.save_screenshot(Rails.root.join("tmp", "system-health-hosted-usage-mobile.png"))
  end

  test "Users page no longer shows the trial expiry summary" do
    label_screenshot_fixtures
    visit admin_users_path

    assert_no_text I18n.t("admin.system_health.hosted_usage.summary.trials_expiring_soon_count", raise: true)
    assert_selector "h1", text: I18n.t("admin.users.index.title")
    page.save_screenshot(Rails.root.join("tmp", "admin-users-without-trial-summary.png"))
  end

  test "unavailable installations omit the tab even when requested in the URL" do
    HostedUsage.stubs(:available?).returns(false)
    HostedUsage.expects(:new).never

    visit admin_system_health_path(tab: "hosted_usage")

    assert_selector "button[role='tab'][aria-selected='true']", text: "Background jobs"
    assert_no_selector "button[role='tab']", text: "Hosted usage"
    assert_no_selector "turbo-frame#hosted_usage", visible: :all
  end

  private
    # Screenshots may be shared in the PR. Use obviously synthetic labels even
    # though this database contains only the repository's test fixtures.
    def label_screenshot_fixtures
      Family.order(:id).each_with_index do |family, index|
        family.update_columns(name: "Fixture household #{index + 1}")
      end
      User.order(:id).each_with_index do |user, index|
        user.update_columns(first_name: "Fixture", last_name: "Member #{index + 1}",
          email: "fixture-member-#{index + 1}@example.invalid")
      end
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
      SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([])
    end
end
