require "application_system_test_case"

class CategoriesTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "can create category" do
    visit categories_url
    click_link I18n.t("categories.new.new_category")
    fill_in "Name", with: "My Shiny New Category"
    click_button "Create Category"

    visit categories_url
    assert_text "My Shiny New Category"
  end

  test "trying to create a duplicate category fails" do
    visit categories_url
    click_link I18n.t("categories.new.new_category")
    fill_in "Name", with: categories(:food_and_drink).name
    click_button "Create Category"

    assert_text "Name has already been taken"
  end

  test "long category names truncate before the actions menu on mobile" do
    category = categories(:food_and_drink)
    category.update!(name: "Super Long Category Name That Should Stop Before The Menu Button On Mobile")

    page.current_window.resize_to(315, 643)

    visit categories_url

    row = find("##{ActionView::RecordIdentifier.dom_id(category)}")
    actions = row.find("[data-testid='category-actions'] button", visible: true)

    assert actions.visible?

    viewport_width = page.evaluate_script("window.innerWidth")
    page_scroll_width = page.evaluate_script("document.documentElement.scrollWidth")

    assert_operator page_scroll_width, :<=, viewport_width
  end
end
