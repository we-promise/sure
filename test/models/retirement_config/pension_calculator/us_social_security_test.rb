require "test_helper"

class RetirementConfig::PensionCalculator::UsSocialSecurityTest < ActiveSupport::TestCase
  setup do
    @config = retirement_configs(:us_retirement)
    @calculator = RetirementConfig::PensionCalculator::UsSocialSecurity.new(@config)
  end

  test "returns estimated_monthly_benefit from pension_params" do
    result = @calculator.estimated_monthly_pension
    assert_equal 2800.0, result
  end

  test "returns 0 when no benefit configured and no entry" do
    @config.pension_params = {}
    result = @calculator.estimated_monthly_pension
    assert_equal 0, result
  end

  test "uses projected_monthly_pension from entry when available" do
    entry = @config.pension_entries.build(
      recorded_at: Date.current,
      projected_monthly_pension: 3000.0
    )
    entry.save!
    calc = RetirementConfig::PensionCalculator::UsSocialSecurity.new(@config)
    assert_equal 3000.0, calc.estimated_monthly_pension
  end

  test "is not points_based" do
    assert_not @calculator.points_based?
  end

  test "param_definitions includes estimated_monthly_benefit" do
    keys = RetirementConfig::PensionCalculator::UsSocialSecurity.param_definitions.map { |d| d[:key] }
    assert_includes keys, "estimated_monthly_benefit"
  end
end
