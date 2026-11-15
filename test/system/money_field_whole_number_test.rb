require "application_system_test_case"

# A whole-number currency (PYG) has no decimal point to type, so the money
# field reads a dot as thousands grouping, and a factor's decimal point must be
# PYG's own (a comma). Text the previous currency could not read stays flagged
# after a currency switch instead of taking the new currency's reading.
class MoneyFieldWholeNumberTest < ApplicationSystemTestCase
  AMOUNT = "entry[amount]".freeze

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false)

    visit new_transaction_url
    choose_currency "PYG"
  end

  test "a PYG field reads grouped thousands and PYG's decimal factor" do
    type_amount "150.000.000"
    assert_equal "150000000", amount_field.value
    assert_equal "", validation_message

    type_amount "150,50*12"
    assert_equal "1806", amount_field.value

    type_amount "150.50*12"
    assert_equal "150.50*12", amount_field.value, "a dot is PYG's thousands delimiter, not a decimal point"
    assert_not_equal "", validation_message
  end

  test "text PYG cannot read stays flagged after switching to USD until it is edited" do
    type_amount "150.000*12"
    assert_not_equal "", validation_message

    choose_currency "USD"
    assert_selector "[data-money-field-target='symbol']", text: "$"
    assert_equal "150.000*12", amount_field.value
    assert_not_equal "", validation_message

    amount_field.click
    amount_field.send_keys(:tab)
    assert_equal "150.000*12", amount_field.value, "leaving the field does not rewrite it as 1800"

    amount_field.send_keys(:end, :backspace, "3")
    assert_equal "", validation_message
  end

  private
    def amount_field
      find_field(AMOUNT)
    end

    def choose_currency(code)
      find("select[name='entry[currency]']").find("option[value='#{code}']").select_option
      assert_selector "[data-money-field-separator-currency-value='#{code}']"
    end

    # Types the text and leaves the field, which normalizes it.
    def type_amount(text)
      amount_field.set(text)
      amount_field.send_keys(:tab)
    end

    def validation_message
      page.evaluate_script("document.querySelector(\"[name='#{AMOUNT}']\").validationMessage")
    end
end
