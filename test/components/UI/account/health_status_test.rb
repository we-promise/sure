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

  test "links a connection that needs reconnecting to its card on the accounts page" do
    item = trade_republic_items(:configured_item)
    item.update!(session_expires_at: 1.minute.ago)
    @account.account_providers.create!(provider: trade_republic_accounts(:main_account))

    render_inline(UI::Account::HealthStatus.new(account: @account))

    assert_text I18n.t("accounts.health_status.provider_reconnect.message", provider: item.institution_display_name)
    assert_link I18n.t("accounts.health_status.provider_reconnect.link"),
                href: Rails.application.routes.url_helpers.accounts_path(anchor: ActionView::RecordIdentifier.dom_id(item))
    assert_no_selector ".translation_missing"
  end

  test "tells a member who can't reconnect to ask an admin" do
    Current.session = users(:family_member).sessions.create!
    trade_republic_items(:configured_item).update!(session_expires_at: 1.minute.ago)
    @account.account_providers.create!(provider: trade_republic_accounts(:main_account))

    render_inline(UI::Account::HealthStatus.new(account: @account))

    assert_text I18n.t("accounts.health_status.provider_reconnect.hint_ask_admin")
    assert_no_link I18n.t("accounts.health_status.provider_reconnect.link")
  end

  test "formats each position's date and quantity the way the family sees them" do
    @account.family.update!(date_format: "%d.%m.%Y")
    @account.stubs(:negative_positions).returns([
      Account::NegativePosition.new(securities(:msft), Date.new(2026, 4, 10), BigDecimal("-1.5"))
    ])

    render_inline(UI::Account::HealthStatus.new(account: @account))

    assert_selector ".privacy-sensitive", exact_text: "Microsoft (MSFT): below zero from 10.04.2026, lowest -1.5"
  end
end
