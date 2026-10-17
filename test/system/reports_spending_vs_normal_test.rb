require "application_system_test_case"

class ReportsSpendingVsNormalTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @account = accounts(:depository)
    @category = @user.family.categories.create!(name: "Treemap Coffee")

    # A year of £10 a month, then £40 this month: four times normal.
    12.times { |i| create_transaction(account: @account, date: Date.current.beginning_of_month - (i + 1).months + 2.days, amount: 10, category: @category) }
    create_transaction(account: @account, date: Date.current.beginning_of_month + 1.day, amount: 40, category: @category)

    sign_in @user
    visit reports_path(period_type: :monthly)
  end

  test "the treemap shows spending against normal and opens a category's transactions" do
    within "section[data-section-key='spending_vs_normal']" do
      assert_selector "[data-controller='spending-treemap'] svg g.leaf rect", minimum: 1
      assert_selector "[data-testid='spending-changes'] li", text: "Treemap Coffee"

      box = find("g.leaf[aria-label^='Treemap Coffee']")
      box.hover
    end

    assert_selector "[role='tooltip']", text: "More than normal by"

    find("g.leaf[aria-label^='Treemap Coffee']").click

    assert_current_path(/\/transactions\?/)
    assert_includes URI.decode_www_form_component(current_url), "Treemap Coffee"
  end
end
