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
        click_button "(uncategorized)"
      end
    end

    assert_selector(
      "##{ActionView::RecordIdentifier.dom_id(entry)}",
      text: "Uncategorized"
    )

    assert_nil transaction.reload.category_id
  end
end
