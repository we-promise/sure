require "test_helper"

class RetirementPlan::ProjectionTest < ActiveSupport::TestCase
  def projection(**overrides)
    RetirementPlan::Projection.new(
      annual_expenses: 40_000,
      annual_income: 60_000,
      current_assets: 250_000,
      safe_withdrawal_rate: BigDecimal("0.04"),
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

  # Integer#clamp hands back the bound itself, so a clamped or guarded zero
  # comes out as an Integer unless the bounds are BigDecimal.
  test "a zero or clamped rate and amount are still BigDecimal" do
    overspending = projection(annual_income: 30_000)
    no_income = projection(annual_income: 0)
    past_fi = projection(current_assets: 1_120_000)
    below_zero = projection(current_assets: -10_000)

    assert_kind_of BigDecimal, overspending.effective_savings_rate
    assert_kind_of BigDecimal, overspending.annual_contribution
    assert_kind_of BigDecimal, no_income.effective_savings_rate
    assert_kind_of BigDecimal, no_income.annual_contribution
    assert_kind_of BigDecimal, past_fi.bar_progress
    assert_kind_of BigDecimal, below_zero.bar_progress
  end

  # Two runs on different days, with no query and no request, must give the
  # same figures.
  test "the projection reads neither the clock, the database nor the current request" do
    Current.expects(:user).never
    Current.expects(:family).never

    runs = [ Date.new(2026, 3, 1), Date.new(2031, 9, 30) ].map do |today|
      travel_to(today) do
        figures = nil
        assert_queries_count(0) do
          figures = [ projection, projection(annual_income: 0) ].map do |p|
            [ p.fi_number, p.progress, p.bar_progress, p.financially_independent?, p.effective_savings_rate,
              p.annual_contribution ]
          end
        end
        figures
      end
    end

    assert_equal runs.first, runs.last
  end
end
