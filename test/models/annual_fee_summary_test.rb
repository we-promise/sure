require "test_helper"

class AnnualFeeSummaryTest < ActiveSupport::TestCase
  setup do
    @card = accounts(:credit_card).credit_card
    @card.account.update!(currency: "EUR")
    @card.update!(annual_fee: 100, annual_fee_month: 1, annual_fee_day: 3)
  end

  test "each fee is converted once, so every total agrees" do
    Money.any_instance.expects(:exchange_to).once.raises(Money::ConversionError.new(from_currency: "EUR", to_currency: "USD", date: Date.new(2027, 1, 1)))

    summary = AnnualFeeSummary.new([ @card ], currency: "USD", as_of: Date.new(2027, 1, 1))

    assert_nil summary.yearly.money
    assert_nil summary.upcoming.money
    assert_equal 1, summary.yearly.unconverted_count
    assert_equal 1, summary.upcoming.unconverted_count
  end
end
