require "test_helper"

class RetirementPlans::PlannerComponentTest < ViewComponent::TestCase
  Milestone = RetirementPlan::Milestones::Milestone

  setup do
    @plan = RetirementPlan.new(birth_year: 1985, end_age: 90, mode: "fire", safe_withdrawal_rate: BigDecimal("0.04"))
    @simulation = RetirementPlan::Simulation.new(
      as_of: Date.new(2026, 11, 23), current_assets: 420_000, annual_contribution: 36_000,
      expected_annual_return: BigDecimal("0.06"), inflation_rate: BigDecimal("0.03"),
      streams: [ RetirementPlan::Simulation::Stream.new(kind: "expense", annual_amount: 42_000) ],
      retirement_year: 2036, birth_year: 1985, end_age: 90
    )
  end

  def render_planner(solution:, fi_100:)
    milestones = [ Milestone.new(key: "fi_50", year: 2028, age: 43, reached_already: false), fi_100 ]
    render_inline(RetirementPlans::PlannerComponent.new(plan: @plan, simulation: @simulation, solution: solution,
                                                        currency: "USD", milestones: milestones))
  end

  def solved(year)
    RetirementPlan::Solver::Result.new(retirement_year: year, retirement_age: year && year - 1985, depletion_age: nil)
  end

  test "a FIRE year before the FI number is reached is explained" do
    render_planner(solution: solved(2036), fi_100: Milestone.new(key: "fi_100", year: nil, age: nil, reached_already: false))

    assert_selector "[data-milestone='fi_100']", text: I18n.t("retirement_plans.planner.milestones.not_reached")
    assert_selector "[data-fire-before-fi-number]", text: /25 times a year of spending, the 4% rule\. Retiring in 2036 .* last to 90/
  end

  test "no explanation when the FI number is reached within the plan" do
    render_planner(solution: solved(2036), fi_100: Milestone.new(key: "fi_100", year: 2037, age: 52, reached_already: false))

    assert_no_selector "[data-fire-before-fi-number]"
  end

  test "no explanation when the FI number is already reached" do
    render_planner(solution: solved(2036), fi_100: Milestone.new(key: "fi_100", year: nil, age: nil, reached_already: true))

    assert_no_selector "[data-fire-before-fi-number]"
  end

  test "no explanation outside FIRE mode" do
    @plan.assign_attributes(mode: "traditional", retirement_date: Date.new(2036, 1, 1))
    render_planner(solution: nil, fi_100: Milestone.new(key: "fi_100", year: nil, age: nil, reached_already: false))

    assert_no_selector "[data-fire-before-fi-number]"
  end
end
