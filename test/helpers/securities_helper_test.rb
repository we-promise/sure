require "test_helper"

class SecuritiesHelperTest < ActionView::TestCase
  include ApplicationHelper

  setup do
    @security = securities(:aapl)
    @security.stubs(:current_price).returns(Money.new(200, "USD"))
  end

  test "shows the converted price with the quote beside it" do
    @security.stubs(:current_price_in).with("EUR").returns(Money.new(180, "EUR"))

    html = current_price_with_quote(@security, "EUR")

    assert_includes html, Money.new(180, "EUR").format
    assert_includes html, "(#{Money.new(200, "USD").format})"
  end

  test "shows only the quote when it is in the currency asked for" do
    @security.stubs(:current_price_in).with("USD").returns(Money.new(200, "USD"))

    assert_equal Money.new(200, "USD").format, current_price_with_quote(@security, "USD")
  end

  test "shows only the quote, under its own currency, without a rate" do
    @security.stubs(:current_price_in).with("EUR").returns(nil)

    assert_equal Money.new(200, "USD").format, current_price_with_quote(@security, "EUR")
  end

  test "shows nothing without a quote" do
    @security.stubs(:current_price).returns(nil)

    assert_nil current_price_with_quote(@security, "EUR")
  end
end
