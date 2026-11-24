require "test_helper"

class UI::Account::HealthStatusTest < ViewComponent::TestCase
  setup do
    @account = accounts(:investment)
    Current.session = sessions(:one)
  end

  teardown { Current.session = nil }

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

  test "formats each position's date and quantity the way the family sees them" do
    @account.family.update!(date_format: "%d.%m.%Y")
    @account.stubs(:negative_positions).returns([
      Account::NegativePosition.new(securities(:msft), Date.new(2026, 4, 10), BigDecimal("-1.5"))
    ])

    render_inline(UI::Account::HealthStatus.new(account: @account))

    assert_selector ".privacy-sensitive", exact_text: "Microsoft (MSFT): below zero from 10.04.2026, lowest -1.5"
  end

  test "states how far the bank's balance is off and since when" do
    @account.family.update!(date_format: "%d.%m.%Y")
    gap = Balance::IntegrityChecker::Gap.new(
      anchor_waypoint: Balance::IntegrityChecker::Waypoint.new(date: Date.new(2026, 4, 1), value: 1000, kind: "reconciliation"),
      first_open_waypoint: Balance::IntegrityChecker::Waypoint.new(date: Date.new(2026, 4, 10), value: 950, kind: "reconciliation"),
      latest_waypoint: Balance::IntegrityChecker::Waypoint.new(date: Date.new(2026, 4, 12), value: 950, kind: "reconciliation"),
      implied_value: 1000, actual_value: 950, difference: -50
    )
    Balance::IntegrityChecker.stubs(:open_gap_for).with(@account).returns(gap)

    render_inline(UI::Account::HealthStatus.new(account: @account))

    assert_text I18n.t("accounts.health_status.balance_gap.message")
    assert_selector ".privacy-sensitive", text: /#{Regexp.escape(Money.new(50, @account.currency).format)} lower .* since 10\.04\.2026/
    assert_link I18n.t("accounts.health_status.balance_gap.link")
    assert_no_selector ".translation_missing"
  end
end
