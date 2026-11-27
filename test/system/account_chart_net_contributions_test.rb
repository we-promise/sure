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
    # The dashed path must be drawn, not merely added: a path with no `d`
    # passes the selector but has no length.
    length = page.evaluate_script("document.querySelector('#lineChart path[stroke-dasharray]').getTotalLength()")
    assert_operator length, :>, 0, "the dashed line has no geometry"
    # Secondary to the value line, so painted under it: earlier in the group.
    painted_first = page.evaluate_script(<<~JS)
      (() => {
        const dashed = document.querySelector('#lineChart path[stroke-dasharray]');
        const value = document.querySelector('#lineChart path[stroke*="split-gradient"]');
        return !!(dashed.compareDocumentPosition(value) & Node.DOCUMENT_POSITION_FOLLOWING);
      })()
    JS
    assert painted_first, "the dashed line must be painted before, so under, the value line"
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
