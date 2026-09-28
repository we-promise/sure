require "application_system_test_case"

class TransactionQuickCategoryCreateTest < ApplicationSystemTestCase
  include ActionView::RecordIdentifier
  include EntriesTestHelper

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

  test "creates a new subcategory from the list's quick picker and assigns it" do
    parent = categories(:food_and_drink)
    visit transactions_url

    within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
      find("button", match: :first).click
    end

    assert_difference "Category.count", +1 do
      within "turbo-frame#category_dropdown" do
        find("input[type='search']").fill_in with: "Quick Picker Subcategory"
        click_button "Add as a subcategory…"
        assert_text 'Create "Quick Picker Subcategory" under:'
        find("button[data-parent-id='#{parent.id}']").click
      end

      assert_selector "##{dom_id(@entry.entryable, 'category_menu_desktop')} [data-testid='category-name']", text: "Quick Picker Subcategory"
    end

    category = @user.family.categories.find_by!(name: "Quick Picker Subcategory")
    assert_equal parent, category.parent
    assert_equal category.id, @entry.entryable.reload.category_id
  end

  test "back from the quick picker's parent list returns to the category list" do
    visit transactions_url

    within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
      find("button", match: :first).click
    end

    within "turbo-frame#category_dropdown" do
      find("input[type='search']").fill_in with: "Changed My Mind"
      click_button "Add as a subcategory…"
      assert_selector "[data-category-quick-create-target='parentPicker']", visible: true

      click_button "Back"
      assert_no_selector "[data-category-quick-create-target='parentPicker']", visible: true
      assert_button 'Create "Changed My Mind"'
    end
  end

  test "hides 'No categories found' while the create option is showing" do
    visit transactions_url
    open_quick_picker

    within "turbo-frame#category_dropdown" do
      find("input[type='search']").fill_in with: "Nothing Matches This"
      assert_button 'Create "Nothing Matches This"'
      assert_no_text "No categories found"
    end
  end

  test "reports a failed assignment after the category was created" do
    visit transactions_url
    open_quick_picker
    assert_selector "turbo-frame#category_dropdown input[type='search']"

    # Let the create request through but block the assign request in the
    # browser, so it fails at the network level with no response to act on.
    browser = page.driver.browser
    browser.execute_cdp("Network.enable")
    browser.execute_cdp("Network.setBlockedURLs", urls: [ "*/transactions/*/category*" ])

    within "turbo-frame#category_dropdown" do
      find("input[type='search']").fill_in with: "Created But Not Assigned"
      click_button 'Create "Created But Not Assigned"'
      assert_selector "[data-category-quick-create-target='error']", text: "couldn't assign it"
    end

    assert @user.family.categories.exists?(name: "Created But Not Assigned")
    assert_not_equal "Created But Not Assigned", @entry.entryable.reload.category&.name
  ensure
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
  end

  private
    def open_quick_picker
      within "##{dom_id(@entry.entryable, 'category_menu_desktop')}" do
        find("button", match: :first).click
      end
    end
end
