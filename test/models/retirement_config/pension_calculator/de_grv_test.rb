require "test_helper"

class RetirementConfig::PensionCalculator::DeGrvTest < ActiveSupport::TestCase
  setup do
    @config = retirement_configs(:dylan_retirement)
    @calculator = RetirementConfig::PensionCalculator::DeGrv.new(@config)
  end

  test "uses projected_monthly_pension from latest entry when available" do
    result = @calculator.estimated_monthly_pension
    assert_equal 1850.0, result
  end

  test "calculates from points and rentenwert when no entry present" do
    @config.pension_entries.delete_all
    @config.instance_variable_set(:@latest_pension_entry, nil)
    @config.pension_params = { "expected_annual_points" => 1.0, "rentenwert" => 39.32 }

    result = @calculator.estimated_monthly_pension
    expected = (0 + 1.0 * @config.years_to_retirement) * 39.32
    assert_in_delta expected, result, 0.01
  end

  test "falls back to default rentenwert when not in pension_params" do
    @config.pension_entries.delete_all
    @config.instance_variable_set(:@latest_pension_entry, nil)
    @config.pension_params = { "expected_annual_points" => 1.0 }

    result = @calculator.estimated_monthly_pension
    expected = (0 + 1.0 * @config.years_to_retirement) * RetirementConfig::PensionCalculator::DeGrv::DEFAULT_RENTENWERT
    assert_in_delta expected, result, 0.01
  end

  test "is points_based" do
    assert @calculator.points_based?
  end

  test "param_definitions returns expected keys" do
    keys = RetirementConfig::PensionCalculator::DeGrv.param_definitions.map { |d| d[:key] }
    assert_includes keys, "expected_annual_points"
    assert_includes keys, "rentenwert"
    assert_includes keys, "contribution_start_year"
  end
end
