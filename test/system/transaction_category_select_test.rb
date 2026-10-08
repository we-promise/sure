require "application_system_test_case"

class TransactionCategorySelectTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "can create a category from the transaction form" do
    visit new_transaction_url

    assert_difference "Category.count", +1 do
      find("[data-controller='category-select'] button").click

      within "[data-controller='category-select']" do
        fill_in "Search categories", with: "Inline Test Category"

        assert_text 'Create "Inline Test Category"'
        click_button 'Create "Inline Test Category"'

        assert_selector(
          "[data-category-select-target='option'][aria-selected='true']",
          text: "Inline Test Category",
          visible: :all
        )
      end
    end

    assert Category.exists?(name: "Inline Test Category")
  end

  test "can clear a category from an existing transaction" do
    transaction = transactions(:one)
    transaction.update!(category: categories(:food_and_drink))
    entry = transaction.entry

    visit transactions_url

    page.execute_script <<~JS
      const frame = document.querySelector("turbo-frame#drawer")
      frame.src = "#{transaction_url(entry)}"
    JS

    within "turbo-frame#drawer", visible: :all do
      assert_selector "[data-controller='category-select']"

      within "[data-controller='category-select']" do
        find("button", match: :first).click
        find("button[data-category-id='']").click
      end
    end

    assert_selector(
      "##{ActionView::RecordIdentifier.dom_id(entry)}",
      text: "Uncategorized"
    )

    assert_nil transaction.reload.category_id
  end

  test "can create a subcategory from the transaction form" do
    parent = categories(:food_and_drink)
    visit new_transaction_url

    assert_difference "Category.count", +1 do
      find("[data-controller='category-select'] button").click

      within "[data-controller='category-select']" do
        fill_in "Search categories", with: "Inline Subcategory"
        click_button "Add as a subcategory…"

        assert_text 'Create "Inline Subcategory" under:'
        find("button[data-parent-id='#{parent.id}']").click

        assert_selector "[data-category-select-target='selectionContainer']", text: "Inline Subcategory"
      end
    end

    assert_equal parent, Category.find_by!(name: "Inline Subcategory").parent
  end

  test "can create a subcategory from the transaction details panel" do
    parent = categories(:food_and_drink)
    transaction = transactions(:one)
    entry = transaction.entry

    visit transactions_url

    page.execute_script <<~JS
      const frame = document.querySelector("turbo-frame#drawer")
      frame.src = "#{transaction_url(entry)}"
    JS

    within "turbo-frame#drawer", visible: :all do
      within "[data-controller='category-select']" do
        find("button", match: :first).click
        fill_in "Search categories", with: "Drawer Subcategory"
        click_button "Add as a subcategory…"
        find("button[data-parent-id='#{parent.id}']").click
      end
    end

    assert_selector "##{ActionView::RecordIdentifier.dom_id(entry)}", text: "Drawer Subcategory"

    category = Category.find_by!(name: "Drawer Subcategory")
    assert_equal parent, category.parent
    assert_equal category.id, transaction.reload.category_id
  end

  test "back from the parent picker returns to the category list" do
    visit new_transaction_url
    find("[data-controller='category-select'] button").click

    within "[data-controller='category-select']" do
      fill_in "Search categories", with: "Changed My Mind"
      click_button "Add as a subcategory…"
      assert_selector "[data-category-select-target='parentPicker']", visible: true

      click_button "Back"
      assert_no_selector "[data-category-select-target='parentPicker']", visible: true
      assert_button 'Create "Changed My Mind"'
    end
  end

  test "the parent picker keeps keyboard focus, and Escape steps back out" do
    visit new_transaction_url
    find("[data-controller='category-select'] button").click

    within "[data-controller='category-select']" do
      fill_in "Search categories", with: "Keyboard Category"
      click_button "Add as a subcategory…"
    end

    assert_equal "parentOption", active_element_attribute("data-category-select-target")

    send_escape
    assert_no_selector "[data-category-select-target='parentPicker']", visible: true
    assert_equal "search", active_element_attribute("data-category-select-target")

    send_escape
    assert_no_selector "[data-category-select-target='menu']", visible: true
    assert_equal "button", active_element_attribute("data-category-select-target")
  end

  test "Enter in the search while the parent picker is open doesn't create a top-level category" do
    visit new_transaction_url
    find("[data-controller='category-select'] button").click

    within "[data-controller='category-select']" do
      fill_in "Search categories", with: "Not Top Level"
      click_button "Add as a subcategory…"
    end

    assert_no_difference "Category.count" do
      page.execute_script("document.querySelector(\"[data-category-select-target='search']\").focus()")
      find("[data-category-select-target='search']").send_keys(:enter)
      assert_selector "[data-category-select-target='parentPicker']", visible: true
      assert_equal "parentOption", active_element_attribute("data-category-select-target")
    end
  end

  test "a new subcategory is listed under its parent straight away" do
    parent = categories(:food_and_drink)
    visit new_transaction_url
    find("[data-controller='category-select'] button").click

    within "[data-controller='category-select']" do
      fill_in "Search categories", with: "Grouped Subcategory"
      click_button "Add as a subcategory…"
      find("button[data-parent-id='#{parent.id}']").click
      # The rows stay disabled until the POST returns; give a slow request time.
      assert_selector "[data-category-select-target='selectionContainer']", text: "Grouped Subcategory", wait: 10
    end

    created = Category.find_by!(name: "Grouped Subcategory")
    group_ids = [ parent.id, *parent.subcategories.where.not(id: created.id).pluck(:id) ].map(&:to_s)
    previous_id = page.evaluate_script(<<~JS)
      document.querySelector("[data-category-select-target='option'][data-category-id='#{created.id}']")
        .previousElementSibling.dataset.categoryId
    JS
    assert_includes group_ids, previous_id
  end

  test "a failed create from the parent picker returns to the list with the error" do
    parent = categories(:food_and_drink)
    visit new_transaction_url
    find("[data-controller='category-select'] button").click

    within "[data-controller='category-select']" do
      fill_in "Search categories", with: "Late Duplicate"
      click_button "Add as a subcategory…"
    end

    # Someone else takes the name after the page loaded, so the server rejects it.
    Category.create!(family: parent.family, name: "Late Duplicate", color: "#e99537")

    within "[data-controller='category-select']" do
      find("button[data-parent-id='#{parent.id}']").click

      assert_selector "[role='alert']", text: "taken", wait: 10
      assert_no_selector "[data-category-select-target='parentPicker']", visible: true
    end
    assert_keyboard_back_in_search
  end

  test "a failed top-level create keeps focus in the menu" do
    visit new_transaction_url
    find("[data-controller='category-select'] button").click

    within "[data-controller='category-select']" do
      fill_in "Search categories", with: "Late Top Level"
    end
    Category.create!(family: users(:family_admin).family, name: "Late Top Level", color: "#e99537")

    within "[data-controller='category-select']" do
      find("[data-category-select-target='createForm']").click
      assert_selector "[role='alert']", text: "taken", wait: 10
    end
    assert_keyboard_back_in_search
  end

  test "a top-level category created inline is offered as a parent without reloading" do
    visit new_transaction_url
    find("[data-controller='category-select'] button").click

    within "[data-controller='category-select']" do
      fill_in "Search categories", with: "Fresh Parent"
      click_button 'Create "Fresh Parent"'
      assert_selector "[data-category-select-target='selectionContainer']", text: "Fresh Parent"
    end

    fresh_parent = Category.find_by!(name: "Fresh Parent")
    find("[data-controller='category-select'] button").click

    within "[data-controller='category-select']" do
      fill_in "Search categories", with: "Fresh Child"
      click_button "Add as a subcategory…"
      find("button[data-parent-id='#{fresh_parent.id}']").click
      assert_selector "[data-category-select-target='selectionContainer']", text: "Fresh Child"
    end

    assert_equal fresh_parent, Category.find_by!(name: "Fresh Child").parent
  end

  private
    def active_element_attribute(name)
      page.evaluate_script("document.activeElement.getAttribute('#{name}')")
    end

    def send_escape
      page.driver.browser.action.send_keys(:escape).perform
    end

    # Focus is back in the search, so Escape closes the menu, not the
    # New transaction dialog around it.
    def assert_keyboard_back_in_search
      assert page.evaluate_script("document.activeElement.matches(\"[data-category-select-target='search']\")"),
        "focus should return to the category search"
      send_escape
      assert_no_selector "[data-category-select-target='menu']", visible: true
      assert_selector "dialog[open]"
    end
end
