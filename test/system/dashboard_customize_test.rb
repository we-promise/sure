require "application_system_test_case"

class DashboardCustomizeTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
  end

  test "hides a widget from the keyboard and adds it back" do
    sign_in @user
    net_worth = I18n.t("pages.dashboard.net_worth_chart.title")

    click_on I18n.t("pages.dashboard.customize.start"), match: :first
    find_button(I18n.t("pages.dashboard.customize.hide", title: net_worth)).send_keys(:enter)

    assert_no_selector "section[data-section-key='net_worth_chart']"

    click_on net_worth
    assert_selector "section[data-section-key='net_worth_chart']"

    click_on I18n.t("pages.dashboard.customize.done")
    assert_no_button I18n.t("pages.dashboard.customize.hide", title: net_worth)
  end
end
