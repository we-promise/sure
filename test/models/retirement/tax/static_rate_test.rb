require "test_helper"

class Retirement::Tax::StaticRateTest < ActiveSupport::TestCase
  StaticRate = Retirement::Tax::StaticRate

  test "flat treatments return their constant" do
    assert_equal 0.74, StaticRate.net_rate("de_bav", retire_year: 2040)
    assert_equal 1.00, StaticRate.net_rate("uk_isa", retire_year: 2040)
    assert_equal 1.00, StaticRate.net_rate("custom_post_tax", retire_year: 2040)
  end

  test "de_renten falls with the cohort year and clamps at the ends" do
    assert_in_delta 0.82, StaticRate.net_rate("de_renten", retire_year: 2025), 0.0001
    assert_in_delta 0.65, StaticRate.net_rate("de_renten", retire_year: 2058), 0.0001
    # midpoint is between the endpoints
    mid = StaticRate.net_rate("de_renten", retire_year: 2041)
    assert mid < 0.82 && mid > 0.65
    # clamps outside the range
    assert_in_delta 0.82, StaticRate.net_rate("de_renten", retire_year: 2010), 0.0001
    assert_in_delta 0.65, StaticRate.net_rate("de_renten", retire_year: 2099), 0.0001
  end

  test "net_at applies the rate to a gross amount" do
    assert_equal 740.to_d, StaticRate.net_at(1000, "de_bav", retire_year: 2040)
  end

  test "unknown treatment raises" do
    assert_raises(ArgumentError) { StaticRate.net_rate("bogus", retire_year: 2040) }
  end
end
