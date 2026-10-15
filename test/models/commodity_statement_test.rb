require "test_helper"

class CommodityStatementTest < ActiveSupport::TestCase
  include CommoditiesTestHelper

  setup do
    travel_to Date.new(2026, 10, 15)
    @family = families(:empty)
    @family.update!(currency: "USD")
    @account = create_commodity_account(family: @family)
    @safe = @family.commodity_locations.create!(name: "Home safe")
    @bank = @family.commodity_locations.create!(name: "Bank deposit box")

    create_commodity_price(code: "XAU", date: Date.current, price: 2500)
    create_commodity_price(code: "XAG", date: Date.current, price: 30)

    @gold = create_commodity_item(account: @account, location: @safe, metal_cost: 2400, premium: 80)
    @silver = create_commodity_item(
      account: @account, location: @bank, code: "XAG", name: "100 g bar", form: "bar",
      weight_value: 100, weight_unit: "g", fineness: BigDecimal("0.999"), metal_cost: 90, premium: 10, vat: 19
    )
    @statement = CommodityStatement.new(@family)
  end

  test "totals per metal and in total" do
    gold, silver = @statement.by_metal.map(&:last)

    assert_equal Money.new(BigDecimal("2499.75"), "USD"), gold.melt_value
    # 99.9 g fine / 31.1034768 = 3.21185958 ozt x 30
    assert_in_delta 96.3558, silver.melt_value.amount, 0.0001
    assert_equal Money.new(2599, "USD"), @statement.total.cost_basis.total
    assert_equal BigDecimal("31.1034768") * BigDecimal("0.9999") + BigDecimal("99.9"), @statement.total.fine_grams
    assert_in_delta(-2.8942, @statement.total.unrealized_trend.value.amount, 0.0001)
  end

  test "totals per location" do
    rows = @statement.by_location.to_h

    assert_equal [ @bank, @safe ], rows.keys
    assert_equal [ @silver ], rows[@bank].items
  end

  test "realized gains from sales" do
    @silver.sales.create!(date: Date.current, quantity: 1, proceeds: 110, costs: 2, currency: "USD")

    # 110 - 2 - (90 + 10 + 19)
    assert_equal Money.new(-11, "USD"), CommodityStatement.new(@family).realized_gain
    assert_equal [ @gold ], CommodityStatement.new(@family).held_items
  end

  test "value series per metal" do
    point = @statement.value_series(period: Period.custom(start_date: Date.current, end_date: Date.current)).sole

    assert_equal %w[Gold Silver], point[:groups].map { |g| g[:name] }
    assert_in_delta 2499.75 + 96.36, point[:value], 0.01
  end
end
