require "application_system_test_case"

class SidekiqHealthBannerTest < ApplicationSystemTestCase
  setup do
    @health = Object.new
    @health.stubs(:healthy?).returns(false)
    @health.stubs(:reason).returns(:queue_backed_up)

    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    Redis.any_instance.stubs(:ping).returns("PONG")
    SidekiqHealth.stubs(:current).returns(@health)
  end

  test "dashboard data warning reserves space instead of overlapping the page header" do
    sign_in users(:sure_support_staff)
    visit root_path

    assert_selector "[data-testid='sidekiq-health-banner']"

    banner_rect = page.evaluate_script("document.querySelector('[data-testid=\"sidekiq-health-banner\"]').getBoundingClientRect()")
    heading_rect = page.evaluate_script("document.querySelector('h1').getBoundingClientRect()")

    assert_operator banner_rect["bottom"], :<=, heading_rect["top"],
      "expected the stale-data warning to finish above the dashboard heading"
  end
end
