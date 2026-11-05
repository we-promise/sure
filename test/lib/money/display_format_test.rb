require "test_helper"

class Money::DisplayFormatTest < ActiveSupport::TestCase
  test "language follows the locale grouping and symbol placement" do
    german = Money::DisplayFormat.for_currency("EUR", locale: :de, amount_format: "language")

    assert_equal "language", german[:key]
    assert_equal "standard", german[:grouping]
    assert_equal ".", german[:delimiter]
    assert_equal ",", german[:separator]
    assert_equal "after", german[:symbol_position]
    assert_equal " ", german[:symbol_spacing]

    polish = Money::DisplayFormat.for_currency("EUR", locale: :pl, amount_format: "language")

    assert_equal "standard", polish[:grouping]
    assert_equal " ", polish[:delimiter]
    assert_equal ",", polish[:separator]
    assert_equal "after", polish[:symbol_position]
    assert_equal " ", polish[:symbol_spacing]

    french = Money::DisplayFormat.for_currency("EUR", locale: :fr, amount_format: "language")

    assert_equal "\u00A0", french[:delimiter]
    assert_equal ",", french[:separator]
    assert_equal "after", french[:symbol_position]
    assert_equal "\u00A0", french[:symbol_spacing]
  end

  test "language uses the currency's default symbol placement" do
    usd = Money::DisplayFormat.for_currency("USD", locale: :en, amount_format: "language")

    assert_equal ",", usd[:delimiter]
    assert_equal ".", usd[:separator]
    assert_equal "before", usd[:symbol_position]
    assert_equal "", usd[:symbol_spacing]
  end

  test "language reports Indian grouping for INR" do
    inr = Money::DisplayFormat.for_currency("INR", locale: :en, amount_format: "language")

    assert_equal "language", inr[:key]
    assert_equal "indian", inr[:grouping]
    assert_equal ",", inr[:delimiter]
    assert_equal ".", inr[:separator]
    assert_equal "before", inr[:symbol_position]
  end

  test "INR reports Indian punctuation under a non-Indian locale" do
    inr = Money::DisplayFormat.for_currency("INR", locale: :de, amount_format: "language")

    assert_equal "indian", inr[:grouping]
    assert_equal ",", inr[:delimiter]
    assert_equal ".", inr[:separator]
    assert_equal "after", inr[:symbol_position]
  end

  test "language reports Indian grouping for Indian locales" do
    inr = Money::DisplayFormat.for_currency("USD", locale: :"en-IN", amount_format: "language")

    assert_equal "indian", inr[:grouping]
  end

  test "Indian locales report Indian separators for non-INR currencies" do
    eur = Money::DisplayFormat.for_currency("EUR", locale: :"en-IN", amount_format: "language")

    assert_equal "indian", eur[:grouping]
    assert_equal ",", eur[:delimiter]
    assert_equal ".", eur[:separator]
  end

  test "an explicit override reports standard grouping for INR" do
    european = Money::DisplayFormat.for_currency("INR", locale: :en, amount_format: "european")
    international = Money::DisplayFormat.for_currency("INR", locale: :en, amount_format: "international")

    assert_equal "standard", european[:grouping]
    assert_equal "standard", international[:grouping]
  end

  test "indian override reports indian grouping with comma and dot" do
    format = Money::DisplayFormat.for_currency("USD", locale: :en, amount_format: "indian")

    assert_equal "indian", format[:key]
    assert_equal "indian", format[:grouping]
    assert_equal ",", format[:delimiter]
    assert_equal ".", format[:separator]
    assert_equal "before", format[:symbol_position]
    assert_equal "", format[:symbol_spacing]
  end

  test "european override reports dot and comma grouping while keeping symbol placement" do
    format = Money::DisplayFormat.for_currency("EUR", locale: :de, amount_format: "european")

    assert_equal "european", format[:key]
    assert_equal "standard", format[:grouping]
    assert_equal ".", format[:delimiter]
    assert_equal ",", format[:separator]
    assert_equal "after", format[:symbol_position]
    assert_equal " ", format[:symbol_spacing]
  end

  test "international override reports standard grouping with comma and dot" do
    format = Money::DisplayFormat.for_currency("EUR", locale: :de, amount_format: "international")

    assert_equal "international", format[:key]
    assert_equal "standard", format[:grouping]
    assert_equal ",", format[:delimiter]
    assert_equal ".", format[:separator]
    assert_equal "after", format[:symbol_position]
    assert_equal " ", format[:symbol_spacing]
  end

  test "uses the user locale, family currency and amount format" do
    user = users(:family_admin)
    user.update_columns(locale: "de", amount_format: "indian")

    format = Money::DisplayFormat.for_user(user)

    assert_equal "indian", format[:key]
    assert_equal "indian", format[:grouping]
    assert_equal user.family.currency, "USD"
  end

  test "falls back to the family locale when the user has none" do
    user = users(:family_admin)
    user.update_columns(locale: nil, amount_format: "language")
    user.family.update_columns(locale: "de")

    format = Money::DisplayFormat.for_user(user)

    assert_equal ".", format[:delimiter]
    assert_equal "after", format[:symbol_position]
  end

  test "falls back to language when the stored amount format is unknown" do
    user = users(:family_admin)
    user.stubs(:effective_amount_format).returns("language")

    format = Money::DisplayFormat.for_user(user)

    assert_equal "language", format[:key]
    assert_equal "standard", format[:grouping]
  end
end
