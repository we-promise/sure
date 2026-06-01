require "test_helper"

class RetirementConfigTest < ActiveSupport::TestCase
  setup do
    @config = retirement_configs(:dylan_retirement)
  end

  test "valid retirement config" do
    assert @config.valid?
  end

  test "requires birth_year" do
    @config.birth_year = nil
    assert_not @config.valid?
  end

  test "target_monthly_income must be positive" do
    @config.target_monthly_income = 0
    assert_not @config.valid?

    @config.target_monthly_income = -1
    assert_not @config.valid?
  end

  test "pension_system must be in allowed list" do
    @config.pension_system = "invalid"
    assert_not @config.valid?
  end

  test "current_age calculated from birth_year" do
    @config.birth_year = 1990
    expected = Date.current.year - 1990
    assert_equal expected, @config.current_age
  end

  test "years_to_retirement returns non-negative value" do
    @config.birth_year = 1990
    @config.retirement_age = 67
    expected = [ 67 - (Date.current.year - 1990), 0 ].max
    assert_equal expected, @config.years_to_retirement
  end

  test "retired? returns true when past retirement age" do
    @config.birth_year = 1940
    @config.retirement_age = 67
    assert @config.retired?
  end

  test "retired? returns false when before retirement age" do
    @config.birth_year = 2000
    @config.retirement_age = 67
    assert_not @config.retired?
  end

  test "estimated_monthly_pension uses latest projected pension when available" do
    assert_equal 1850.0, @config.estimated_monthly_pension
  end

  test "monthly_pension_gap is non-negative" do
    assert @config.monthly_pension_gap >= 0
  end

  test "fire_number is positive when target income is positive" do
    assert @config.fire_number > 0
  end

  test "fire_progress_pct is between 0 and 100" do
    pct = @config.fire_progress_pct
    assert pct >= 0
    assert pct <= 100
  end

  test "capital_needed_for_gap returns 0 when no gap exists" do
    @config.target_monthly_income = 0.01
    @config.stubs(:estimated_monthly_pension_after_tax).returns(1000)
    assert_equal 0, @config.capital_needed_for_gap
  end

  test "required_monthly_savings returns 0 when no capital needed" do
    @config.stubs(:capital_needed_for_gap).returns(0)
    assert_equal 0, @config.required_monthly_savings
  end
end
