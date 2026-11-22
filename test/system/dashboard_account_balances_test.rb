require "application_system_test_case"

class DashboardAccountBalancesTest < ApplicationSystemTestCase
  include EntriesTestHelper

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

      # The "Cash only" preset keeps cash and cards, drops the rest.
      assert chart.has_css?("svg path[data-key='#{accounts(:investment).id}']", visible: :all)
      click_on "Cash only"
      assert chart.has_no_css?("svg path[data-key='#{accounts(:investment).id}']", visible: :all)
      click_on "All"
      assert chart.has_css?("svg path[data-key='#{accounts(:investment).id}']", visible: :all)

      # Unticking a group takes its accounts out of the chart.
      find("[data-group='CreditCard'] [data-group-check]").click
      assert chart.has_no_css?("svg path[data-key='#{accounts(:credit_card).id}']", visible: :all)
      assert chart.has_css?("svg path[data-key='#{accounts(:depository).id}']", visible: :all)
    end

    # The choice is saved with the user's dashboard preferences.
    assert_eventually { @user.reload.account_balances_settings["hidden_account_ids"].include?(accounts(:credit_card).id) }
  end

  test "a change made right before leaving the dashboard is still saved" do
    sign_in @user

    within "section[data-section-key='account_balances']" do
      find("[data-list-toggle]", match: :first).click
      find("[data-group='CreditCard'] [data-group-check]").click
    end
    # Leave at once, before the debounced save fires: removing the widget
    # disconnects its controller the way a quick Turbo navigation does.
    page.execute_script("document.querySelector('[data-controller=\"account-balances-chart\"]').remove()")

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

  test "a single transaction in the lane opens in the drawer, keeping the dashboard" do
    entry = create_transaction(account: accounts(:depository), amount: 42, name: "Lane bakery", date: 12.days.ago.to_date)
    @user.update!(preferences: @user.preferences.merge("account_balances" => { "show_transactions" => true }))
    sign_in @user

    within "section[data-section-key='account_balances']" do
      find("[data-account-balances-chart-target='chart'] [data-transaction-id='#{entry.id}']", match: :first).click
    end

    within "#drawer" do
      assert_field with: "Lane bakery"
    end
    assert_current_path root_path
    assert_selector "section[data-section-key='account_balances']", visible: :all
  end

  private
    def assert_eventually(timeout: 5)
      deadline = Time.current + timeout
      sleep 0.1 until yield || Time.current > deadline
      assert yield
    end
end
