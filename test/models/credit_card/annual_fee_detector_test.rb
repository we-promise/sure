require "test_helper"

class CreditCard::AnnualFeeDetectorTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:credit_card)
    @card = @account.credit_card
    @card.update!(annual_fee: nil, annual_fee_month: nil, annual_fee_day: nil)
  end

  test "takes the largest fee charge of the last year as the renewal" do
    charge("Membership Fee", 75, Date.new(2026, 2, 20))
    charge("RENEWAL MEMBERSHIP FEE", 450, Date.new(2026, 9, 8))
    charge("WAREHOUSE CLUB *ANNUAL RENEWAL", 60, Date.new(2026, 9, 1))

    result = CreditCard::AnnualFeeDetector.new(@card, as_of: Date.new(2026, 11, 17)).apply!

    assert_equal 450, result.amount
    assert_equal 450, @card.reload.annual_fee
    assert_equal [ 9, 8 ], [ @card.annual_fee_month, @card.annual_fee_day ]
  end

  test "a fee refunded soon after is treated as waived" do
    charge("Annual Membership Fee", 200, Date.new(2026, 7, 3))
    charge("Annual Fee Refund", -200, Date.new(2026, 8, 10))

    result = CreditCard::AnnualFeeDetector.new(@card, as_of: Date.new(2026, 11, 17)).apply!

    assert result.refunded
    assert_nil @card.reload.annual_fee
    assert_equal 7, @card.annual_fee_month
  end

  test "keeps what the user already entered" do
    @card.update!(annual_fee: 300, annual_fee_month: 6, annual_fee_day: 5)
    charge("Annual Fee", 250, Date.new(2026, 6, 20))

    CreditCard::AnnualFeeDetector.new(@card, as_of: Date.new(2026, 11, 17)).apply!

    assert_equal [ 300, 6, 5 ], [ @card.reload.annual_fee, @card.annual_fee_month, @card.annual_fee_day ]
  end

  test "ignores charges older than about 13 months" do
    charge("Annual Fee", 80, Date.new(2024, 1, 1))

    assert_nil CreditCard::AnnualFeeDetector.new(@card, as_of: Date.new(2026, 11, 17)).detect
  end

  private
    def charge(name, amount, date)
      @account.entries.create!(name: name, amount: amount, currency: "USD", date: date, entryable: Transaction.new)
    end
end
