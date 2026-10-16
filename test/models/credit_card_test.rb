require "test_helper"

class CreditCardTest < ActiveSupport::TestCase
  test "debt from available credit is the limit minus the reported amount" do
    assert_equal BigDecimal("16.17"),
      CreditCard.debt_from_available_credit(credit_limit: BigDecimal("5000"), available_credit: BigDecimal("4983.83"), clamp_overpayment: false)
  end

  test "an overpayment stays a credit balance unless clamped" do
    assert_equal BigDecimal("-20"),
      CreditCard.debt_from_available_credit(credit_limit: BigDecimal("5000"), available_credit: BigDecimal("5020"), clamp_overpayment: false)
    assert_equal 0,
      CreditCard.debt_from_available_credit(credit_limit: BigDecimal("5000"), available_credit: BigDecimal("5020"), clamp_overpayment: true)
  end

  test "the debt is unknown without a positive limit" do
    assert_nil CreditCard.debt_from_available_credit(credit_limit: nil, available_credit: BigDecimal("10"), clamp_overpayment: true)
    assert_nil CreditCard.debt_from_available_credit(credit_limit: BigDecimal("0"), available_credit: BigDecimal("10"), clamp_overpayment: true)
  end
end
