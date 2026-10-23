require "application_system_test_case"

# The +/−/×/÷ row under a money field belongs to that field. It used to key off
# an unnamed `group-focus-within`, which matches any `.group` ancestor, and
# every DS::Dialog section is one (DS::Disclosure), so focusing the
# transaction's name in the drawer showed the row too.
class MoneyFieldOperatorsTest < ApplicationSystemTestCase
  OPERATOR_ROW = "button[aria-label='Add']".freeze

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false)
  end

  test "the operator row shows for the transaction drawer's amount, not its name" do
    entry = transactions(:one).entry

    visit transactions_url
    page.execute_script <<~JS
      document.querySelector("turbo-frame#drawer").src = "#{transaction_url(entry)}"
    JS

    within "turbo-frame#drawer" do
      find_field("entry[name]").click
      assert_no_selector OPERATOR_ROW

      find_field("entry[amount]").click
      assert_selector OPERATOR_ROW

      find_field("entry[name]").click
      assert_no_selector OPERATOR_ROW
    end
  end

  test "the operator row stays reachable by Tab from the new transaction's amount" do
    visit new_transaction_url

    fill_in "Description", with: "Groceries"
    assert_no_selector OPERATOR_ROW

    find_field("entry[amount]").click
    assert_selector OPERATOR_ROW

    # Amount → currency select → first operator button.
    find_field("entry[amount]").send_keys(:tab)
    page.driver.browser.action.send_keys(:tab).perform
    assert_equal "Add", page.evaluate_script("document.activeElement.getAttribute('aria-label')")

    fill_in "Description", with: "Groceries"
    assert_no_selector OPERATOR_ROW
  end
end
