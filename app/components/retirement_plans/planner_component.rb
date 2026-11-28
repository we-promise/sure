# frozen_string_literal: true

# The planner's outcome, milestones, chart and year-by-year table.
#
# Formatting only: every figure comes from the RetirementPlan::Simulation
# (and, in FIRE mode, the RetirementPlan::Solver result) the controller built
# with its one reference date.
class RetirementPlans::PlannerComponent < ViewComponent::Base
  attr_reader :plan, :simulation, :solution, :currency, :milestones

  def initialize(plan:, simulation:, solution:, currency:, milestones: [])
    @plan = plan
    @simulation = simulation
    @solution = solution
    @currency = currency
    @milestones = milestones
  end

  def fire?
    plan.mode == "fire"
  end

  # What stops the page from showing a table, if anything.
  def missing_input
    return :birth_year if plan.birth_year.nil?
    return :retirement_date if !fire? && plan.retirement_date.nil?
    # Born after this year, an end age already past, or retiring after it.
    return :years if fire? ? solution.nil? : simulation.nil?

    nil
  end

  def rows
    simulation&.rows || []
  end

  def row_attributes(row)
    { data: { year: row.year, retired: (true if row.year >= simulation.retirement_year) }.compact }
  end

  def row_class(row)
    "bg-warning/10" if row.year == simulation.depletion_year
  end

  # The milestones reached within the plan, by the year they land in.
  def milestones_in(year)
    @milestones_by_year ||= milestones.select(&:year).group_by(&:year)
    @milestones_by_year.fetch(year, [])
  end

  def coast?
    milestones.any? { |milestone| milestone.key == "coast" }
  end

  # A FIRE year only needs the money to last to the end age, counting income
  # such as a pension and spending that stops, so it can come before the
  # portfolio reaches the FI number. Said when it does, so the two figures
  # don't read as a contradiction.
  def fi_before_fi_number?
    fire? && solution.retirement_year.present? &&
      milestones.any? { |milestone| milestone.key == "fi_100" && milestone.year.nil? && !milestone.reached_already }
  end

  def fi_before_fi_number_note
    rate = plan.safe_withdrawal_rate
    t("retirement_plans.planner.milestones.fire_before_fi_number",
      multiple: helpers.number_with_precision(1 / rate, precision: 1, strip_insignificant_zeros: true),
      rate: helpers.number_to_percentage(rate * 100, precision: 2, strip_insignificant_zeros: true),
      year: solution.retirement_year, end_age: plan.end_age)
  end

  def milestone_name(milestone)
    t("retirement_plans.planner.milestones.names.#{milestone.key}")
  end

  def milestone_when(milestone)
    if milestone.reached_already
      t("retirement_plans.planner.milestones.reached")
    elsif milestone.year
      t("retirement_plans.planner.milestones.in_year", year: milestone.year, age: milestone.age)
    else
      t("retirement_plans.planner.milestones.not_reached")
    end
  end

  def money(amount)
    Money.new(amount, currency).format(precision: 0)
  end

  # The portfolio at each year end, in today's money.
  def chart_series
    Series.from_raw_values(
      rows.map { |row| { date: Date.new(row.year, 12, 31), value: Money.new(row.end_value_real.round(2), currency) } },
      interval: "1 year"
    )
  end
end
