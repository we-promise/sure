require "application_system_test_case"

class TransactionQuickCategoryCreateTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier

  setup do
    sign_in @user = users(:family_admin)
    @entry = @user.family.entries.transactions.order(date: :desc).first
    page.current_window.resize_to(1280, 900)
  end

  test "creates a new category from the list's quick picker and assigns it" do
    visit transactions_url

    within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
      find("button", match: :first).click
    end

    assert_difference "Category.count", +1 do
      within "turbo-frame#category_dropdown" do
        find("input[type='search']").fill_in with: "Quick Picker Category"
        click_button 'Create "Quick Picker Category"'
      end

      # The update response re-renders the row's category menu with the new category.
      assert_selector "##{dom_id(@entry.entryable, 'category_menu_desktop')} [data-testid='category-name']", text: "Quick Picker Category"
    end

    category = @user.family.categories.find_by!(name: "Quick Picker Category")
    assert_equal category.id, @entry.entryable.reload.category_id
  end

  test "hides the create option when the search exactly matches an existing category" do
    existing = @user.family.categories.alphabetically.first

    visit transactions_url

    within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
      find("button", match: :first).click
    end

    within "turbo-frame#category_dropdown" do
      find("input[type='search']").fill_in with: existing.name.upcase
      assert_no_button "Create \"#{existing.name.upcase}\""
    end
  end
end
