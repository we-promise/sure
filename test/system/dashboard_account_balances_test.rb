require "application_system_test_case"

class DashboardAccountBalancesTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
  end

  test "stacks a layer per account, lists them by type and narrows the chart from the list" do
    sign_in @user

    within "section[data-section-key='account_balances']" do
      chart = find("[data-account-balances-chart-target='chart']", match: :first)
      assert chart.has_css?("svg path[data-key='#{accounts(:depository).id}']", visible: :all)
      assert chart.has_css?("svg path[data-key='#{accounts(:credit_card).id}']", visible: :all)

      # The account list starts folded; opening it shows the type groups.
      find("[data-list-toggle]", match: :first).click
      assert_selector "[data-group='Depository']"
      assert_selector "[data-group='CreditCard']"

      # Unticking a group takes its accounts out of the chart.
      find("[data-group='CreditCard'] [data-group-check]").click
      assert chart.has_no_css?("svg path[data-key='#{accounts(:credit_card).id}']", visible: :all)
      assert chart.has_css?("svg path[data-key='#{accounts(:depository).id}']", visible: :all)
    end

    # The choice is saved with the user's dashboard preferences.
    assert_eventually { @user.reload.account_balances_settings["hidden_account_ids"].include?(accounts(:credit_card).id) }
  end

  test "opens full screen from the widget header" do
    sign_in @user

    within "section[data-section-key='account_balances']" do
      find("button[data-action='click->cashflow-expand#open']", visible: :all).click
      within "dialog#account-balances-expanded-dialog" do
        assert_selector "[data-account-balances-chart-target='chart'] svg"
      end
    end
  end

  private
    def assert_eventually(timeout: 5)
      deadline = Time.current + timeout
      sleep 0.1 until yield || Time.current > deadline
      assert yield
    end
end
