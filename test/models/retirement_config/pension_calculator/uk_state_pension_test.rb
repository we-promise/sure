require "test_helper"

class RetirementConfig::PensionCalculator::UkStatePensionTest < ActiveSupport::TestCase
  setup do
    @config = retirement_configs(:us_retirement)
    @config.pension_system = "uk_sp"
    @config.pension_params = { "qualifying_years" => 35, "full_weekly_rate" => 221.20 }
    @calculator = RetirementConfig::PensionCalculator::UkStatePension.new(@config)
  end

  test "calculates full pension for 35 qualifying years" do
    result = @calculator.estimated_monthly_pension
    expected = (35.0 / 35.0) * 221.20 * 52 / 12
    assert_in_delta expected, result, 0.01
  end

  test "calculates partial pension for fewer qualifying years" do
    @config.pension_params = { "qualifying_years" => 20, "full_weekly_rate" => 221.20 }
    result = @calculator.estimated_monthly_pension
    expected = (20.0 / 35.0) * 221.20 * 52 / 12
    assert_in_delta expected, result, 0.01
  end

  test "returns 0 when no qualifying years" do
    @config.pension_params = { "qualifying_years" => 0 }
    assert_equal 0, @calculator.estimated_monthly_pension
  end

  test "falls back to default weekly rate" do
    @config.pension_params = { "qualifying_years" => 35 }
    result = @calculator.estimated_monthly_pension
    expected = 1.0 * RetirementConfig::PensionCalculator::UkStatePension::FULL_WEEKLY_RATE * 52 / 12
    assert_in_delta expected, result, 0.01
  end

  test "is not points_based" do
    assert_not @calculator.points_based?
  end

  test "param_definitions includes qualifying_years and full_weekly_rate" do
    keys = RetirementConfig::PensionCalculator::UkStatePension.param_definitions.map { |d| d[:key] }
    assert_includes keys, "qualifying_years"
    assert_includes keys, "full_weekly_rate"
  end
end
