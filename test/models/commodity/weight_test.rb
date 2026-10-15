require "test_helper"

class Commodity::WeightTest < ActiveSupport::TestCase
  test "converts troy ounces to grams with the exact constant" do
    assert_equal BigDecimal("31.1034768"), Commodity::Weight.to_grams(1, "ozt")
    assert_equal BigDecimal("3110.34768"), Commodity::Weight.to_grams(100, "ozt")
    assert_equal BigDecimal("100"), Commodity::Weight.to_grams(100, "g")
  end

  test "round-trips grams through troy ounces without drift" do
    grams = Commodity::Weight.to_grams(BigDecimal("0.5"), "ozt")
    assert_equal BigDecimal("0.5"), Commodity::Weight.from_grams(grams, "ozt").round(12)
  end

  test "converts 100 g to troy ounces" do
    assert_in_delta 3.2150746569, Commodity::Weight.from_grams(100, "ozt"), 1e-9
  end

  test "formats grams and troy ounces with unit-appropriate precision" do
    assert_equal "100.00 g", Commodity::Weight.format(100, "g")
    assert_equal "0.5000 g", Commodity::Weight.format(BigDecimal("0.5"), "g")
    assert_equal "3.215 oz t", Commodity::Weight.format(100, "ozt")
    assert_equal "0.9999 oz t", Commodity::Weight.format(BigDecimal("31.1034768") * BigDecimal("0.9999"), "ozt")
  end
end
