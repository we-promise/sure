require "test_helper"

class EquityGrantTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:investment)
    @account.investment.update!(subtype: "stock_plan")
    @grant = @account.equity_grants.create!(ticker: "acme", grant_identifier: "RS1", grant_date: Date.new(2025, 3, 1), total_units: 240)
    @grant.vests.create!(vest_date: Date.new(2026, 3, 15), units: 60)
    @grant.vests.create!(vest_date: Date.new(2026, 6, 15), units: 60)
    @grant.vests.create!(vest_date: Date.new(2027, 3, 15), units: 60)
  end

  test "ticker and grant ID are normalized, a blank ID becomes nil" do
    blank = @account.equity_grants.create!(ticker: " acme ", grant_identifier: "  ")
    another = @account.equity_grants.create!(ticker: "ACME", grant_identifier: "")

    assert_equal "ACME", @grant.ticker
    assert_nil blank.grant_identifier
    assert_nil another.grant_identifier
  end

  test "grants live only on stock plan accounts" do
    grant = accounts(:depository).equity_grants.build(ticker: "ACME")

    assert_not grant.valid?
    assert grant.errors.of_kind?(:account, :not_a_stock_plan)
  end

  test "rejects identifiers and tickers longer than their columns" do
    assert_not @account.equity_grants.build(ticker: "A" * 21).valid?
    assert_not @account.equity_grants.build(ticker: "ACME", grant_identifier: "G" * 101).valid?
  end

  test "splits units into vested and unvested as of a date" do
    as_of = Date.new(2026, 9, 1)

    assert_equal 120, @grant.vested_units(as_of: as_of)
    # 240 granted, 120 vested, 60 scheduled: the unscheduled remainder still counts as unvested.
    assert_equal 120, @grant.unvested_units(as_of: as_of)
  end

  test "a forfeited grant has nothing unvested and its later vests don't count" do
    @grant.update!(forfeited_on: Date.new(2026, 4, 1))
    as_of = Date.new(2026, 9, 1)

    assert_equal 60, @grant.vested_units(as_of: as_of)
    assert_equal 0, @grant.unvested_units(as_of: as_of)
  end

  test "values unvested RSUs at the latest stored price of the resolved security" do
    security = Security.create!(ticker: "ACME", name: "Acme Corp")
    security.prices.create!(date: Date.current, price: 200, currency: "USD")
    @grant.update_columns(security_id: security.id)

    grant = EquityGrant.find(@grant.id)
    assert_equal Money.new(200, "USD") * grant.unvested_units, grant.unvested_value
  end

  test "options are valued above their strike, and not at all without one" do
    security = Security.create!(ticker: "ACME", name: "Acme Corp")
    security.prices.create!(date: Date.current, price: 50, currency: "USD")
    option = @account.equity_grants.create!(ticker: "ACME", grant_type: "option", total_units: 100)
    option.update_columns(security_id: security.id)

    assert_nil EquityGrant.find(option.id).unit_value

    option.update_columns(strike_price: 30)
    assert_equal Money.new(20, "USD"), EquityGrant.find(option.id).unit_value

    option.update_columns(strike_price: 80)
    assert_equal Money.new(0, "USD"), EquityGrant.find(option.id).unit_value
  end

  test "has no value until its security has been resolved" do
    assert_nil EquityGrant.find(@grant.id).latest_price
  end

  test "looks up its security in the background when the ticker changes" do
    assert_enqueued_with(job: EquityGrantSecurityJob) { @grant.update!(ticker: "ACMX") }
  end

  test "grant identifiers are unique per account" do
    assert_not @account.equity_grants.build(ticker: "ACME", grant_identifier: "RS1").valid?
  end

  test "a vest date is unique within a grant" do
    assert_not @grant.vests.build(vest_date: Date.new(2026, 3, 15), units: 1).valid?
  end
end
