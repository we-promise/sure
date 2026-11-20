require "application_system_test_case"

class AccountActivityUncategorizedFilterTest < ApplicationSystemTestCase
  include EntriesTestHelper
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
    @uncategorized = create_transaction(account: @account, name: "Uncategorized Filter Target", category: nil)
    @categorized = create_transaction(account: @account, name: "Categorized Filter Decoy", category: categories(:food_and_drink))
    page.current_window.resize_to(1280, 900)
  end

  test "the activity filter can narrow the list to uncategorized transactions" do
    visit account_url(@account, tab: "activity")
    assert_selector "##{dom_id(@categorized)}"
    assert_selector "##{dom_id(@uncategorized)}"

    find("#activity-filters-button").click

    within "#transaction-filters-menu" do
      find("button[data-id='category_filter']").click
      check Category.uncategorized.display_name, allow_label_click: true
      click_button "Apply"
    end

    assert_no_selector "##{dom_id(@categorized)}"
    assert_selector "##{dom_id(@uncategorized)}"
  end
end
