require "test_helper"

class BondTest < ActiveSupport::TestCase
  test "returns original balance from bond lots when present" do
    account = accounts(:bond)

    assert_equal 15000, account.bond.original_balance.amount
    assert_equal "USD", account.bond.original_balance.currency.iso_code
  end

  test "auto-assigns maturity date from term months" do
    bond = Bond.new(term_months: 6, maturity_date: nil)

    bond.valid?

    assert_equal Time.zone.today + 6.months, bond.maturity_date
  end

  test "is an asset accountable type" do
    assert_equal "asset", Bond.classification
    assert_equal "badge-percent", Bond.icon
  end

  test "normalizes legacy EOD subtype to inflation_linked" do
    bond = Bond.new(subtype: "eod")

    bond.valid?

    assert_equal "inflation_linked", bond.subtype
  end
end
