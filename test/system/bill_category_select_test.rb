require "application_system_test_case"

# The bill form's category picker finds a category by name and keeps a
# subcategory under its parent, the way the transaction form's picker does.
# A flat list of every category puts a subcategory among unrelated
# neighbours, and a family with many categories scrolls to find one.
class BillCategorySelectTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @recurring = recurring_transactions(:netflix_subscription)
  end

  test "the bill edit form finds a category by name and keeps it under its parent" do
    visit edit_recurring_transaction_url(@recurring)

    within "[data-controller='category-select']" do
      find("button", match: :first).click

      # The picker searches, so a category is found by name, not by scrolling.
      fill_in "Search categories", with: "Restaurants"
      assert_selector "[data-category-select-target='option']:not(.hidden)", text: "Restaurants"

      # A subcategory sits under its parent, not among unrelated neighbours.
      names = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("[data-category-select-target='option']"))
          .map((option) => option.dataset.categoryName)
      JS

      assert_operator names.index("Food & Drink"), :<, names.index("Restaurants")
    end
  end
end
