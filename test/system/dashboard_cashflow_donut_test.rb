require "application_system_test_case"

class DashboardCashflowDonutTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    account = @user.family.accounts.first
    create_transaction(account: account, name: "Salary", amount: -100_000, category: categories(:income))
    create_transaction(account: account, name: "Groceries", amount: 100, category: categories(:food_and_drink))
  end

  test "draws inflows and outflows as two concentric rings with the surplus closing the inner ring" do
    sign_in @user

    within "#cashflow-donut-section" do
      rings = all("g.ring", visible: :all)
      assert_equal 2, rings.size

      assert rings.first.has_css?("path.visible-path[data-segment-id='income_#{categories(:income).id}']", visible: :all)
      assert rings.last.has_no_css?("path.visible-path[data-segment-id='income_#{categories(:income).id}']", visible: :all)
      assert rings.last.has_css?("path.visible-path[data-segment-id='surplus']", visible: :all)
      assert_text "Net Cash Flow"
    end
  end
end
