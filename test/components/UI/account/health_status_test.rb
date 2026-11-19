require "test_helper"

class UI::Account::HealthStatusTest < ViewComponent::TestCase
  setup do
    @account = accounts(:investment)
  end

  test "renders nothing for a healthy account" do
    render_inline(UI::Account::HealthStatus.new(account: @account))

    assert_no_selector "[data-testid='account-health-status']"
  end

  test "renders each issue with its details and link" do
    @account.syncs.create!(status: :failed, failed_at: 1.hour.ago)
    @account.stubs(:negative_positions).returns([
      Account::NegativePosition.new(securities(:msft), 3.days.ago.to_date, -3)
    ])

    render_inline(UI::Account::HealthStatus.new(account: @account))

    assert_selector "[data-testid='account-health-status']"
    assert_text I18n.t("accounts.health_status.sync_failed.message")
    assert_text I18n.t("accounts.health_status.negative_positions.message")
    assert_selector ".privacy-sensitive", text: /Microsoft \(MSFT\)/
    assert_text I18n.t("accounts.health_status.negative_positions.hint")
    assert_link I18n.t("accounts.health_status.negative_positions.link"),
                href: Rails.application.routes.url_helpers.account_path(@account, tab: "holdings")
    assert_no_selector ".translation_missing"
  end
end
