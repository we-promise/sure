require "test_helper"

class Purchase::ValidatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "a consistent order has no problems" do
    assert_empty problems
  end

  test "items plus shipping minus discounts must equal the total" do
    assert_equal [ "items_mismatch" ], reasons(total: BigDecimal("240.00"))
    assert_empty reasons(total: BigDecimal("239.99"), discount_total: BigDecimal("10.00"))
  end

  test "a discount the item prices already include is not a mismatch" do
    items = [ { "name" => "Filter", "amount" => "43.68" }, { "name" => "Bags", "amount" => "29.90" } ]

    assert_empty reasons(items:, total: BigDecimal("73.58"), shipping_cost: BigDecimal("0"), discount_total: BigDecimal("10.95"))
  end

  test "a total that matches neither with nor without the discount is a mismatch" do
    items = [ { "name" => "Filter", "amount" => "43.68" }, { "name" => "Bags", "amount" => "29.90" } ]

    found = problems(items:, total: BigDecimal("80.00"), shipping_cost: BigDecimal("0"), discount_total: BigDecimal("10.95"))
      .find { _1["reason"] == "items_mismatch" }

    assert_equal({ "reason" => "items_mismatch", "expected" => "62.63", "actual" => "80.0", "items" => "73.58",
                   "shipping" => "0.0", "discount" => "10.95" }, found)
  end

  test "the mismatch check allows one cent of rounding" do
    assert_empty reasons(total: BigDecimal("250.00"))
  end

  test "no items means nothing to compare" do
    assert_empty reasons(items: [])
  end

  test "missing and non-positive totals" do
    assert_includes reasons(total: nil), "missing_total"
    assert_includes reasons(total: BigDecimal("0"), items: []), "non_positive_total"
  end

  test "missing, future and too old dates" do
    assert_includes reasons(order_date: nil), "missing_date"
    assert_includes reasons(order_date: Date.current + 1.day), "future_date"
    assert_includes reasons(order_date: Date.current - 1.year - 1.day), "too_old"
  end

  test "unknown currency" do
    assert_includes reasons(currency: "XYZ"), "unknown_currency"
    assert_includes reasons(currency: nil), "unknown_currency"
  end

  test "item categories that are not the family's" do
    items = [ { "name" => "A", "amount" => "249.99", "category_name" => "Not A Category" } ]

    found = problems(items:, shipping_cost: nil).find { _1["reason"] == "unknown_categories" }

    assert_equal [ "Not A Category" ], found["names"]
  end

  private
    def problems(**overrides)
      Purchase::Validator.new(build_purchase_extraction(**overrides), family: @family).problems
    end

    def reasons(**overrides)
      problems(**overrides).map { _1["reason"] }
    end
end
