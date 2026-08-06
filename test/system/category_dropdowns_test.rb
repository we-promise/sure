require "application_system_test_case"

class CategoryDropdownsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @transaction = transactions(:one)
    visit category_dropdown_url(category_id: @transaction.category_id, transaction_id: @transaction.id)
  end

  test "unmatched search offers the original category name" do
    fill_in "Search", with: "  Coffee & Tea  "

    add_link = find("a[data-list-filter-target='addItem']")
    assert add_link.visible?
    assert_equal "+ Add Coffee & Tea Category", add_link.text.strip
    assert_selector "[data-list-filter-target='emptyMessage'].hidden", visible: :all
    assert_includes add_link[:href], "name=Coffee+%26+Tea"
  end

  test "keyboard navigation highlights and activates the add category link" do
    fill_in "Search", with: "Keyboard Category"
    input = find("input[data-list-filter-target='input']")

    input.send_keys(:arrow_down)
    assert_selector "a[data-list-filter-target='addItem'].bg-container-inset-hover[aria-selected='true']"

    input.send_keys(:enter)
    assert_selector "#modal"
  end
end
