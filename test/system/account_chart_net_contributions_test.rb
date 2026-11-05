require "application_system_test_case"

# The net contributions line is drawn by the chart controller in the
# browser, so only a browser shows it is there. An account that holds trades
# gets the dashed line and its legend on the Total value view; any other
# account keeps the single-line chart.
class AccountChartNetContributionsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
  end

  test "an investment account draws the dashed net contributions line and its legend" do
    account = accounts(:investment)
    assert account.supports_trades?, "the fixture must hold trades, or this asserts nothing"

    sign_in @user
    visit account_url(account, chart_view: "balance")

    assert_selector "#lineChart path[stroke-dasharray]", visible: :all
    assert_selector "[data-net-contributions-legend]", text: I18n.t("UI.account.chart.net_contributions.label")
  end

  test "a depository account draws neither" do
    account = accounts(:depository)

    sign_in @user
    visit account_url(account)

    # The chart must have drawn before its absence means anything.
    assert_selector "#lineChart path", visible: :all
    assert_no_selector "#lineChart path[stroke-dasharray]", visible: :all
    assert_no_selector "[data-net-contributions-legend]"
  end
end
