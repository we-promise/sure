require "test_helper"

class RetirementConfig::PensionCalculator::FrRegimeGeneralTest < ActiveSupport::TestCase
  setup do
    @config = retirement_configs(:us_retirement)
    @config.pension_system = "fr_regime"
    @config.pension_params = { "estimated_monthly_pension" => 1600.0, "trimestres" => 120 }
    @calculator = RetirementConfig::PensionCalculator::FrRegimeGeneral.new(@config)
  end

  test "returns estimated_monthly_pension from pension_params" do
    assert_equal 1600.0, @calculator.estimated_monthly_pension
  end

  test "returns 0 when no pension configured and no entry" do
    @config.pension_params = {}
    assert_equal 0, @calculator.estimated_monthly_pension
  end

  test "uses projected_monthly_pension from entry when available" do
    entry = @config.pension_entries.build(
      recorded_at: Date.current,
      projected_monthly_pension: 1700.0
    )
    entry.save!
    calc = RetirementConfig::PensionCalculator::FrRegimeGeneral.new(@config)
    assert_equal 1700.0, calc.estimated_monthly_pension
  end

  test "is not points_based" do
    assert_not @calculator.points_based?
  end

  test "param_definitions includes trimestres and estimated_monthly_pension" do
    keys = RetirementConfig::PensionCalculator::FrRegimeGeneral.param_definitions.map { |d| d[:key] }
    assert_includes keys, "trimestres"
    assert_includes keys, "estimated_monthly_pension"
  end
end
