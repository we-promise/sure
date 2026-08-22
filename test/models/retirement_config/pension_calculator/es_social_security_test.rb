require "test_helper"

class RetirementConfig::PensionCalculator::EsSocialSecurityTest < ActiveSupport::TestCase
  setup do
    @config = retirement_configs(:us_retirement)
    @config.pension_system = "es_ss"
    @config.pension_params = { "estimated_monthly_pension" => 1400.0, "contribution_years" => 30 }
    @calculator = RetirementConfig::PensionCalculator::EsSocialSecurity.new(@config)
  end

  test "returns estimated_monthly_pension from pension_params" do
    assert_equal 1400.0, @calculator.estimated_monthly_pension
  end

  test "returns 0 when no pension configured and no entry" do
    @config.pension_params = {}
    assert_equal 0, @calculator.estimated_monthly_pension
  end

  test "uses projected_monthly_pension from entry when available" do
    entry = @config.pension_entries.build(
      recorded_at: Date.current,
      projected_monthly_pension: 1500.0
    )
    entry.save!
    calc = RetirementConfig::PensionCalculator::EsSocialSecurity.new(@config)
    assert_equal 1500.0, calc.estimated_monthly_pension
  end

  test "is not points_based" do
    assert_not @calculator.points_based?
  end

  test "param_definitions includes contribution_years and estimated_monthly_pension" do
    keys = RetirementConfig::PensionCalculator::EsSocialSecurity.param_definitions.map { |d| d[:key] }
    assert_includes keys, "contribution_years"
    assert_includes keys, "estimated_monthly_pension"
  end
end
