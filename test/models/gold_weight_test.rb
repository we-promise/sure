require "test_helper"

class GoldWeightTest < ActiveSupport::TestCase
  test "converts supported gold units to grams" do
    assert_equal 10.to_d, GoldWeight.in_grams(10, "gram")
    assert_equal 1_000.to_d, GoldWeight.in_grams(1, "kilogram")
    assert_equal GoldWeight::TROY_OUNCE_GRAMS, GoldWeight.in_grams(1, "troy_ounce")
  end

  test "returns zero for missing or invalid values" do
    assert_equal 0.to_d, GoldWeight.in_grams(nil, "gram")
    assert_equal 0.to_d, GoldWeight.in_grams(1, "unknown")
  end
end
