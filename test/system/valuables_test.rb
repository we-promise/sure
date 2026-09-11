require "application_system_test_case"

class ValuablesTest < ApplicationSystemTestCase
  test "creates a collection and values a purchase without a pricing provider" do
    sign_in users(:family_admin)
    visit new_valuable_path
    fill_in "account[name]", with: "Family gold"
    find("form[action='#{valuables_path}'] [type='submit']").click
    assert_text "Family gold"
    click_link "Add item"
    fill_in "valuable_item[description]", with: "Wedding bracelet"
    fill_in "valuable_item[acquired_on]", with: Date.current
    select "Bullion", from: "valuable_item[item_type]"
    select "Gold", from: "valuable_item[material]"
    fill_in "valuable_item[weight]", with: "25"
    select "Grams", from: "valuable_item[weight_unit]"
    fill_in "valuable_item[purity]", with: "91.667"
    fill_in "valuable_item[cost_amount]", with: "2000"
    fill_in "valuable_item[manual_value]", with: "2200"
    find("form[action='#{valuable_items_path}'] [type='submit']").click
    assert_text "Wedding bracelet"
    account = Account.find_by!(name: "Family gold")
    assert_equal 2200, account.balance
    assert_no_link "Statements"
    assert_no_link "Holdings"
    assert_no_lot_overflow
    page.save_screenshot(Rails.root.join("tmp/screenshots/gems-and-bullion-desktop.png"))
    page.current_window.resize_to(390, 844)
    assert_text "Wedding bracelet"
    page.execute_script("arguments[0].scrollIntoView({block: 'center', behavior: 'instant'})", find("[data-testid='valuable-item']"))
    assert_no_lot_overflow
    page.save_screenshot(Rails.root.join("tmp/screenshots/gems-and-bullion-mobile.png"))
  end

  private
    def assert_no_lot_overflow
      assert_selector "[data-testid='valuable-item']", minimum: 1
      assert page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll('[data-testid="valuable-item"]')).every(row => row.scrollWidth <= row.clientWidth)
      JS
    end
end
