require "test_helper"

class Commodity::SaleTest < ActiveSupport::TestCase
  include CommoditiesTestHelper

  setup do
    @account = create_commodity_account(currency: "EUR")
    @item = create_commodity_item(
      account: @account, code: "XAG", name: "1 oz Philharmoniker", quantity: 10, weight_value: 1, weight_unit: "ozt",
      fineness: BigDecimal("0.999"), purchase_currency: "EUR", metal_cost: 250, premium: 50, vat: 57, shipping: 13
    )
  end

  test "partial sale realizes proceeds minus costs minus proportional basis" do
    sale = @item.sales.create!(date: Date.current, quantity: 4, proceeds: 160, costs: 4, currency: "EUR")

    # basis: (250 + 50 + 57 + 13) = 370 for 10 pieces => 148 for 4; net proceeds 156
    trend = sale.realized_gain_loss
    assert_equal Money.new(156, "EUR"), trend.current
    assert_equal Money.new(148, "EUR"), trend.previous
    assert_equal Money.new(8, "EUR"), trend.value

    assert_equal 6, @item.reload.remaining_quantity
    assert_equal Money.new(222, "EUR"), @item.cost_basis.total
    assert @item.held?
  end

  test "selling all pieces marks the item sold" do
    @item.sales.create!(date: Date.current, quantity: 10, proceeds: 400, currency: "EUR")

    assert_not @item.reload.held?
    assert_includes Commodity::Item.sold, @item
  end

  test "cannot sell more than held" do
    @item.sales.create!(date: Date.current, quantity: 8, proceeds: 1, currency: "EUR")
    sale = @item.sales.build(date: Date.current, quantity: 3, proceeds: 1, currency: "EUR")

    assert_not sale.valid?
    assert sale.errors.added?(:quantity, :exceeds_held)
  end

  test "deleting a sale restores held quantity" do
    sale = @item.sales.create!(date: Date.current, quantity: 4, proceeds: 160, currency: "EUR")
    sale.destroy!

    assert_equal 10, @item.reload.remaining_quantity
  end

  test "realized P&L is unknown when the sale-date exchange rate is missing" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)
    sale = @item.sales.create!(date: Date.current, quantity: 1, proceeds: 40, currency: "USD")

    assert_nil sale.realized_gain_loss
  end
end
