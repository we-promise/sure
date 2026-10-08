require "test_helper"

class RetirementPlan::ProjectionTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 1, 15)

  def projection(**overrides)
    RetirementPlan::Projection.new(
      as_of: AS_OF,
      annual_expenses: 40_000,
      annual_income: 60_000,
      current_assets: 250_000,
      safe_withdrawal_rate: BigDecimal("0.04"),
      expected_annual_return: BigDecimal("0.05"),
      **overrides
    )
  end

  test "the FI number for 40,000 of annual expenses at a 4% withdrawal rate is 1,000,000" do
    assert_equal BigDecimal("1000000"), projection.fi_number
  end

  test "progress is liquid and investment assets over the FI number" do
    assert_equal BigDecimal("0.25"), projection(current_assets: 250_000).progress
  end

  test "the bar stops at 100% while the figure beside it does not" do
    past_fi = projection(current_assets: 1_120_000)

    assert_equal BigDecimal("1.12"), past_fi.progress
    assert_equal BigDecimal("1"), past_fi.bar_progress
    assert past_fi.financially_independent?
    assert_not projection(current_assets: 999_999).financially_independent?
  end

  test "with no expenses there is no FI number to measure against" do
    empty = projection(annual_expenses: 0)

    assert_nil empty.fi_number
    assert_nil empty.progress
    assert_nil empty.bar_progress
    assert_not empty.financially_independent?
  end

  # V(n+1) = V(n) * (1 + r) + C: annual compounding, the contribution at the
  # end of each year. Named because "to the cent" means nothing until the
  # recurrence is fixed.
  test "a 5% return matches a hand-computed table to the cent for three years" do
    plan = projection(current_assets: 100_000, annual_income: 100_000, savings_rate: BigDecimal("0.10"),
                      retirement_date: AS_OF.advance(years: 3))

    assert_equal [ "100000.00", "115000.00", "130750.00", "147287.50" ],
                 plan.yearly_series.map { |point| format("%.2f", point[:value]) }
    assert_equal BigDecimal("147287.50"), plan.projected_total
  end

  test "at a 0% return the projected total is the start plus a straight sum of contributions" do
    plan = projection(current_assets: 100_000, annual_income: 100_000, savings_rate: BigDecimal("0.10"),
                      expected_annual_return: 0, retirement_date: AS_OF.advance(years: 4))

    assert_equal BigDecimal("140000"), plan.projected_total
  end

  test "each point is dated a whole year on from the reference date" do
    plan = projection(retirement_date: AS_OF.advance(years: 2))

    assert_equal [ AS_OF, Date.new(2027, 1, 15), Date.new(2028, 1, 15) ], plan.yearly_series.map { |point| point[:date] }
  end

  test "a retirement date short of a full year counts only completed years" do
    assert_equal 2, projection(retirement_date: Date.new(2029, 1, 14)).years_to_retirement
    assert_equal 3, projection(retirement_date: Date.new(2029, 1, 15)).years_to_retirement
  end

  test "a retirement date already passed projects nothing forward" do
    plan = projection(retirement_date: AS_OF - 1)

    assert_equal 0, plan.years_to_retirement
    assert_equal BigDecimal("250000"), plan.projected_total
  end

  test "without a retirement date there is no projected total, but the chart still runs a default horizon" do
    plan = projection

    assert_nil plan.projected_total
    assert_equal RetirementPlan::Projection::DEFAULT_HORIZON_YEARS + 1, plan.yearly_series.size
  end

  test "a saved savings rate is used as given" do
    assert_equal BigDecimal("6000"), projection(savings_rate: BigDecimal("0.10")).annual_contribution
  end

  test "with no saved savings rate it is derived from income and expenses" do
    plan = projection(annual_income: 60_000, annual_expenses: 45_000)

    assert_equal BigDecimal("0.25"), plan.effective_savings_rate
    assert_equal BigDecimal("15000"), plan.annual_contribution
  end

  test "a derived savings rate never goes negative when spending exceeds income" do
    plan = projection(annual_income: 30_000, annual_expenses: 45_000)

    assert_equal 0, plan.effective_savings_rate
    assert_equal 0, plan.annual_contribution
  end

  test "with no income there is nothing to contribute" do
    plan = projection(annual_income: 0, savings_rate: BigDecimal("0.20"))

    assert_equal 0, plan.annual_contribution
  end

  # Date-sensitive models take the reference date as an argument and never
  # derive it. Scanning the source is the only test that fails the moment
  # someone reaches for the clock inside a method body.
  test "nothing under the retirement plan reads the clock or the current request" do
    sources = [ Rails.root.join("app/models/retirement_plan.rb"), *Dir[Rails.root.join("app/models/retirement_plan/**/*.rb")] ]
    offenders = sources.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        code = line.sub(/#.*/, "")
        "#{File.basename(path)}:#{index + 1}" if code.match?(/Date\.(current|today)|Time\.(current|now)|DateTime\.now|\bCurrent\./)
      end
    end

    assert_empty offenders
  end
end
