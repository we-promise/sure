require "test_helper"

class SettleMaturedBondLotsJobTest < ActiveJob::TestCase
  test "settles matured lots with auto-close enabled" do
    lot = BondLot.create!(
      bond: accounts(:bond).bond,
      purchased_on: Date.current - 2.years,
      amount: 1000,
      subtype: "other_bond",
      term_months: 12,
      interest_rate: 10,
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      auto_close_on_maturity: true,
      tax_strategy: "standard",
      tax_rate: 19
    )

    assert_nil lot.closed_on

    SettleMaturedBondLotsJob.perform_now

    assert_not_nil lot.reload.closed_on
  end
end
