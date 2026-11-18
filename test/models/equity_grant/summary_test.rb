require "test_helper"

class EquityGrant::SummaryTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
    @account.investment.update!(subtype: "stock_plan")
    @priced = @account.equity_grants.create!(ticker: "ACME", grant_identifier: "A")
    @priced.vests.create!(vest_date: Date.current + 30, units: 10)
    @unpriced = @account.equity_grants.create!(ticker: "OTHR", grant_identifier: "B")
    @unpriced.vests.create!(vest_date: Date.current + 60, units: 5)
    security = Security.create!(ticker: "ACME", name: "Acme Corp")
    security.prices.create!(date: Date.current, price: 100, currency: "USD")
    @priced.update_columns(security_id: security.id)
  end

  test "a grant without a price is counted, not dropped from the total" do
    total = EquityGrant::Summary.new(@account).unvested_total

    assert_equal Money.new(1000, "USD"), total.money
    assert_equal 1, total.unvalued_count
    assert_not total.complete?
  end

  test "upcoming vests are in date order and exclude forfeited ones" do
    @unpriced.update!(forfeited_on: Date.current)

    upcoming = EquityGrant::Summary.new(@account).upcoming

    assert_equal [ @priced.vests.first ], upcoming.map(&:last)
  end
end
