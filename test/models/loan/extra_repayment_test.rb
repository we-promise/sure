require "test_helper"

class Loan::ExtraRepaymentTest < ActiveSupport::TestCase
  # Blank and zero both mean "no extra": the tab then shows the loan without
  # one, exactly as it does before anything is entered.
  test "a blank or zero amount is no extra, and no error" do
    [ nil, "", "  ", "0", "0.00" ].each do |input|
      extra = Loan::ExtraRepayment.new(amount: input, currency: "USD")

      assert extra.valid?, "#{input.inspect} is not an error"
      assert_not extra.applied?, "#{input.inspect} applies no extra"
      assert_nil extra.amount
    end
  end

  # The params arrive over GET, so the form's `min: 0` is a hint and nothing
  # more. A negative extra would shrink each repayment and manufacture a
  # balloon; it is refused rather than coerced to zero or to its absolute value.
  test "a negative or non-numeric amount is refused, not coerced" do
    [ "-1", "-0.01", "abc", "12abc", "1e3", "Infinity", "NaN" ].each do |input|
      extra = Loan::ExtraRepayment.new(amount: input, currency: "USD")

      assert_not extra.valid?, "#{input.inspect} must be refused"
      assert_not extra.applied?
      assert_nil extra.amount
      assert_equal [ I18n.t("loans.tabs.extra_repayments.invalid_amount") ], extra.errors[:amount]
    end
  end

  test "the smallest positive amount applies" do
    extra = Loan::ExtraRepayment.new(amount: "0.01", currency: "USD")

    assert extra.valid?
    assert extra.applied?
    assert_equal BigDecimal("0.01"), extra.amount
  end

  test "an amount keeps what was typed for the field" do
    assert_equal "250.50", Loan::ExtraRepayment.new(amount: " 250.50 ", currency: "USD").input
    assert_equal "abc", Loan::ExtraRepayment.new(amount: "abc", currency: "USD").input
  end

  # More decimals than the currency has would ask the engine for a repayment
  # nobody can pay. Rounded to the currency, a fraction of a cent is no extra.
  test "an amount is taken to the currency's precision" do
    assert_equal BigDecimal("10.13"), Loan::ExtraRepayment.new(amount: "10.125", currency: "USD").amount
    assert_not Loan::ExtraRepayment.new(amount: "0.004", currency: "USD").applied?
    assert_equal BigDecimal("10"), Loan::ExtraRepayment.new(amount: "10.4", currency: "JPY").amount
  end
end
