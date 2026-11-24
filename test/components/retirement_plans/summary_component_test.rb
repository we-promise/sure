require "test_helper"

class RetirementPlans::SummaryComponentTest < ViewComponent::TestCase
  def projection(**overrides)
    RetirementPlan::Projection.new(
      as_of: Date.new(2026, 1, 1), annual_expenses: 40_000, annual_income: 100_000, current_assets: 250_000,
      safe_withdrawal_rate: BigDecimal("0.04"), expected_annual_return: BigDecimal("0.05"), **overrides
    )
  end

  test "shows the FI number, progress and the derived savings rate" do
    render_inline(RetirementPlans::SummaryComponent.new(projection: projection, currency: "USD"))

    assert_selector "[data-fi-number]", text: "$1,000,000"
    assert_selector "[data-fi-progress]", text: "25%"
    assert_selector "[data-fi-bar][style*='inline-size: 25.0%']"
    assert_text "60%"
    assert_text I18n.t("retirement_plans.summary.derived")
    assert_text I18n.t("retirement_plans.summary.no_retirement_date")
  end

  # Independence needs progress of at least 1, so the figure and the bar must
  # not reach 100 before it.
  test "progress just short of the FI number does not read as 100%" do
    render_inline(RetirementPlans::SummaryComponent.new(projection: projection(current_assets: 996_000), currency: "USD"))

    assert_selector "[data-fi-progress]", text: "99% of the way"
    assert_no_text "Financially independent"
  end

  test "the bar just short of the FI number stops short of full" do
    render_inline(RetirementPlans::SummaryComponent.new(projection: projection(current_assets: 999_600), currency: "USD"))

    assert_selector "[role=progressbar][aria-valuenow='99.9']"
    assert_selector "[data-fi-bar][style*='inline-size: 99.9%']"
  end

  # The hint names the spending the FI number comes from, which with the
  # withdrawal rate gives the number away, so it hides with the figures.
  test "the FI number and the spending behind it are both privacy-sensitive" do
    render_inline(RetirementPlans::SummaryComponent.new(projection: projection, currency: "USD"))

    assert_selector ".privacy-sensitive[data-fi-number]", text: "$1,000,000"
    assert_selector "p.privacy-sensitive", text: "$40,000 a year of spending"
  end

  test "a saved savings rate is not called derived, and a retirement date gives a projected total" do
    render_inline(RetirementPlans::SummaryComponent.new(
      projection: projection(savings_rate: BigDecimal("0.1"), retirement_date: Date.new(2029, 1, 1)), currency: "USD"
    ))

    assert_no_text I18n.t("retirement_plans.summary.derived")
    # 250,000 grown three years at 5% with 10,000 a year added.
    assert_text "$320,931"
  end

  test "says how many accounts were left out for want of a rate" do
    render_inline(RetirementPlans::SummaryComponent.new(projection: projection, currency: "USD", unconverted_count: 2))

    assert_selector ".text-warning", text: I18n.t("retirement_plans.summary.unconverted", count: 2)
  end
end
