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

  test "can search the icon picker and save the icon it finds" do
    visit categories_url
    click_link I18n.t("categories.new.new_category")
    fill_in "Name", with: "Takeout"

    picker = find("summary[aria-label='#{I18n.t("categories.form.trigger_label")}']")
    picker.click

    # Exact-match on `data-controller` so this can't pick up the parent-category
    # `DS::Select`, whose own search field lives under "select list-filter ...".
    within "[data-controller='list-filter']" do
      search = find("input[type='search']")

      search.set("zzzz")
      assert_text I18n.t("ds.icon_picker.no_matching_icons")

      search.set("pizza")
      assert_selector "label[data-filter-name='pizza']"
      assert_no_selector "label[data-filter-name='coffee']"

      find("label[data-filter-name='pizza']").click
    end

    picker.click

    click_button "Create Category"

    # Wait for the redirect back to the list before reading the record —
    # `click_button` returns before the Turbo round-trip finishes.
    assert_text "Takeout"

    assert_equal "pizza", @user.family.categories.find_by!(name: "Takeout").lucide_icon
  end

  test "reopening the icon picker clears the previous search" do
    visit categories_url
    click_link I18n.t("categories.new.new_category")

    picker = find("summary[aria-label='#{I18n.t("categories.form.trigger_label")}']")
    picker.click

    within "[data-controller='list-filter']" do
      find("input[type='search']").set("pizza")
      assert_no_selector "label[data-filter-name='coffee']"
    end

    picker.click
    picker.click

    within "[data-controller='list-filter']" do
      assert_selector "label[data-filter-name='coffee']"
      assert_equal "", find("input[type='search']").value
    end
  end

  test "pressing enter in the icon search does not submit the category form" do
    visit categories_url
    click_link I18n.t("categories.new.new_category")
    fill_in "Name", with: "Not Saved Yet"

    find("summary[aria-label='#{I18n.t("categories.form.trigger_label")}']").click

    within "[data-controller='list-filter']" do
      search = find("input[type='search']")
      search.set("pizza")
      search.send_keys(:enter)
    end

    # Round-trip to the index before reading the record. Capybara's negative
    # matchers return as soon as they hold, so asserting straight after the
    # keypress would pass while an accidental POST was still in flight.
    visit categories_url
    assert_no_text "Not Saved Yet"
    assert_nil @user.family.categories.find_by(name: "Not Saved Yet")
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
