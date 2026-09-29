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
    assert_link "View system health", href: admin_system_health_path

    banner_rect = page.evaluate_script("document.querySelector('[data-testid=\"sidekiq-health-banner\"]').getBoundingClientRect()")
    heading_rect = page.evaluate_script("document.querySelector('h1').getBoundingClientRect()")

    assert_operator banner_rect["bottom"], :<=, heading_rect["top"],
      "expected the stale-data warning to finish above the dashboard heading"
  end

  test "German super admin sees localized warning and each failure reason" do
    users(:sure_support_staff).update!(locale: "de")
    sign_in users(:sure_support_staff)

    SidekiqHealth::REASONS.each do |reason|
      @health.stubs(:reason).returns(reason)
      visit root_path
      within "[data-testid='sidekiq-health-banner']" do
        assert_text "Einige Daten sind möglicherweise nicht aktuell"
        assert_text "Hintergrundaufgaben werden nicht verarbeitet."
        assert_text I18n.t("shared.sidekiq_health_banner.reasons.#{reason}", locale: :de, fallback: false, raise: true)
        assert_link "Systemstatus anzeigen", href: admin_system_health_path
      end
    end
    %w[title body cta].each do |key|
      assert_kind_of String, I18n.t("shared.sidekiq_health_banner.#{key}", locale: :de, fallback: false, raise: true)
    end
  end

  test "German family admin does not see the operator warning" do
    users(:family_admin).update!(locale: "de")
    sign_in users(:family_admin)
    visit root_path

    assert_no_selector "[data-testid='sidekiq-health-banner']"
  end
end
