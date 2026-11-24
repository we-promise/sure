require "application_system_test_case"

# A whole-number currency (PYG) has no decimal point to type, so the money
# field reads a dot as thousands grouping, and a factor's decimal point must be
# PYG's own (a comma). Text PYG read as grouping but rejected stays flagged
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

  test "grouped text PYG rejects stays flagged after switching to USD until it is edited" do
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

  test "grouped text PYG rejects stays flagged through a second switch" do
    type_amount "150.000*12"
    choose_currency "USD"
    assert_selector "[data-money-field-target='symbol']", text: "$"

    choose_currency "EUR"
    assert_selector "[data-money-field-target='symbol']", text: "€"
    assert_not_equal "", validation_message

    amount_field.click
    amount_field.send_keys(:tab)
    assert_equal "150.000*12", amount_field.value
  end

  test "grouped text PYG rejects stays flagged on a restored copy of the page" do
    type_amount "150.000*12"
    choose_currency "USD"
    assert_selector "[data-money-field-target='symbol']", text: "$"

    # Turbo restores a cached copy of the page on back navigation: a clone of
    # the form, with its typed values and its select's choice, and a new
    # controller.
    page.execute_script(<<~JS)
      const form = document.querySelector("[name='#{AMOUNT}']").closest("form");
      const copy = form.cloneNode(true);
      form.querySelectorAll("select").forEach((select, i) => { copy.querySelectorAll("select")[i].value = select.value; });
      form.replaceWith(copy);
    JS

    assert_equal "150.000*12", amount_field.value
    assert_selector "[name='#{AMOUNT}']:invalid"
  end

  test "flagged text replaced by the same text is read with the new currency" do
    type_amount "150.000*12"
    choose_currency "USD"
    assert_selector "[data-money-field-target='symbol']", text: "$"
    assert_selector "[name='#{AMOUNT}']:invalid"

    # Select all and paste the same expression: the paste handler leaves an
    # expression to the browser, whose input event carries the same value.
    page.execute_script(<<~JS)
      const field = document.querySelector("[name='#{AMOUNT}']");
      field.value = "150.000*12";
      field.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertFromPaste" }));
    JS

    assert_selector "[name='#{AMOUNT}']:valid"
  end

  test "an amount PYG rejects without a grouping reading is read as USD after the switch" do
    type_amount "25.50"
    assert_not_equal "", validation_message

    choose_currency "USD"
    assert_selector "[data-money-field-target='symbol']", text: "$"
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
