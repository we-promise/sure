require "test_helper"

class Commodity::ItemTest < ActiveSupport::TestCase
  include CommoditiesTestHelper

  setup do
    @account = create_commodity_account(currency: "EUR")
  end

  test "stores entered weight in grams and computes fine weight" do
    krugerrand = create_commodity_item(
      account: @account, name: "Krugerrand", weight_value: BigDecimal("1.0909"), weight_unit: "ozt",
      fineness: BigDecimal("0.9167"), purchase_currency: "EUR"
    )

    assert_equal BigDecimal("1.0909") * BigDecimal("31.1034768"), krugerrand.gross_weight_grams
    # 33.93078284 g gross x 0.9167 = 31.104 g fine (~1.000 ozt)
    assert_in_delta 31.1043486, krugerrand.fine_grams, 1e-6
    assert_in_delta 1.00002803, krugerrand.fine_troy_ounces, 1e-7
    assert_equal BigDecimal("1.0909"), krugerrand.reload.weight_value
  end

  test "fine weight of a multi-piece silver bar lot at .999" do
    bars = create_commodity_item(
      account: @account, code: "XAG", name: "100 g bar", form: "bar", quantity: 3,
      weight_value: 100, weight_unit: "g", fineness: BigDecimal("0.999"), purchase_currency: "EUR", metal_cost: 270
    )

    assert_equal BigDecimal("299.7"), bars.fine_grams
    assert_equal BigDecimal("300"), bars.gross_grams
  end

  test "cost basis is metal + premium + other costs, converted at the purchase-date rate" do
    purchase_date = 30.days.ago.to_date
    create_rate(from: "USD", to: "EUR", date: purchase_date, rate: 0.9)

    item = create_commodity_item(
      account: @account, purchase_date: purchase_date, purchase_currency: "USD",
      metal_cost: 2000, premium: 80, vat: 0, shipping: 15, insurance: 5
    )

    basis = item.cost_basis
    assert_equal Money.new(1800, "EUR"), basis.metal
    assert_equal Money.new(72, "EUR"), basis.premium
    assert_equal Money.new(18, "EUR"), basis.other
    assert_equal Money.new(1890, "EUR"), basis.total
  end

  test "cost basis is unknown when the purchase-date exchange rate is missing" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    item = create_commodity_item(account: @account, purchase_currency: "USD")

    assert_nil item.cost_basis
    assert_nil item.unrealized_trend
  end

  test "unrealized P&L splits into metal price gain and premium/costs paid" do
    purchase_date = 30.days.ago.to_date
    create_rate(from: "USD", to: "EUR", date: purchase_date, rate: 0.9)
    create_rate(from: "USD", to: "EUR", date: Date.current, rate: 0.92)
    create_commodity_price(code: "XAU", date: Date.current, price: 2500)

    item = create_commodity_item(
      account: @account, purchase_date: purchase_date, purchase_currency: "USD",
      metal_cost: 2000, premium: 80, shipping: 15, insurance: 5
    )

    # 2500 USD/ozt x 0.92 = 2300 EUR/ozt; 0.9999 fine ozt => 2299.77 EUR
    assert_equal Money.new(BigDecimal("2299.77"), "EUR"), item.melt_value
    trend = item.unrealized_trend
    assert_equal Money.new(BigDecimal("409.77"), "EUR"), trend.value
    assert_equal Money.new(BigDecimal("499.77"), "EUR"), item.metal_gain
    assert_equal Money.new(-90, "EUR"), -item.cost_basis.premium_and_costs
    assert_equal trend.value, item.metal_gain - item.cost_basis.premium_and_costs
  end

  test "realisable value at a dealer buyback percentage of spot" do
    create_commodity_price(code: "XAU", date: Date.current, price: 2500, currency: "EUR")
    item = create_commodity_item(account: @account, sell_back_mode: "spot_percent", sell_back_value: 99)

    # 0.9999 ozt x 2500 x 99% = 2474.7525
    assert_equal Money.new(BigDecimal("2474.7525"), "EUR"), item.realisable_value
  end

  test "realisable value at a fixed price per piece" do
    item = create_commodity_item(account: @account, quantity: 2, sell_back_mode: "per_piece", sell_back_value: 2100)

    assert_equal Money.new(4200, "EUR"), item.realisable_value
  end

  test "rejects items in non-commodity accounts" do
    item = Commodity::Item.new(account: accounts(:depository), code: "XAU", name: "x", weight_value: 1, weight_unit: "g",
                               fineness: 1, purchase_date: Date.current, purchase_currency: "USD")

    assert_not item.valid?
    assert item.errors.added?(:account, :invalid)
  end

  test "moving an item records history" do
    safe = families(:dylan_family).commodity_locations.create!(name: "Home safe")
    vault = families(:dylan_family).commodity_locations.create!(name: "Dealer vault")
    item = create_commodity_item(account: @account, location: safe)

    item.move_to!(vault, on: Date.current)

    assert_equal vault, item.reload.location
    move = item.moves.sole
    assert_equal [ safe, vault, Date.current ], [ move.from_location, move.to_location, move.moved_on ]
  end
end
