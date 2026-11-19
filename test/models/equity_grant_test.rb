require "test_helper"

class EquityGrantTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:other_asset)
    @grant = @account.equity_grants.create!(ticker: "acme", grant_identifier: "RS1", grant_date: Date.new(2025, 3, 1), total_units: 240)
    @grant.vests.create!(vest_date: Date.new(2026, 3, 15), units: 60)
    @grant.vests.create!(vest_date: Date.new(2026, 6, 15), units: 60)
    @grant.vests.create!(vest_date: Date.new(2027, 3, 15), units: 60)
  end

  test "ticker is normalized" do
    assert_equal "ACME", @grant.ticker
  end

  test "splits units into vested and unvested as of a date" do
    as_of = Date.new(2026, 9, 1)

    assert_equal 120, @grant.vested_units(as_of: as_of)
    # 240 granted, 120 vested, 60 scheduled: the unscheduled remainder still counts as unvested.
    assert_equal 120, @grant.unvested_units(as_of: as_of)
  end

  test "values unvested units at the latest stored price" do
    security = Security.create!(ticker: "ACME", name: "Acme Corp")
    security.prices.create!(date: Date.current, price: 200, currency: "USD")

    grant = EquityGrant.find(@grant.id)
    assert_equal Money.new(200, "USD") * grant.unvested_units, grant.unvested_value
  end

  test "falls back to a provider quote when Sure has no stored price" do
    quote = Struct.new(:price, :currency).new(BigDecimal("250"), "USD")
    security = Struct.new(:quote) { def find_or_fetch_price = quote }.new(quote)
    Security::Resolver.any_instance.stubs(:resolve).returns(security)

    assert_equal Money.new(250, "USD"), EquityGrant.find(@grant.id).latest_price
  end

  test "grant identifiers are unique per account" do
    duplicate = @account.equity_grants.build(ticker: "ACME", grant_identifier: "RS1")

    assert_not duplicate.valid?
  end
end
