# Monte Carlo for the year-by-year planner.
#
# Pure, like RetirementPlan::Simulation: every input is handed in, the seed
# among them, and nothing here reads the clock, the database or the current
# request.
#
# Each year's return is drawn from a log-normal whose median is the plan's
# expected return:
#
#   1 + r_t = (1 + r) * exp(sigma * z_t),  z_t ~ N(0, 1)
#
# so with sigma = 0 every path is the deterministic projection, and a return
# can never fall below -100%. A path whose withdrawal the portfolio cannot
# meet has run out and counts as a failure.
#
# The year's contribution and withdrawal do not depend on returns, so they
# come from RetirementPlan::Simulation once per retirement year and are
# replayed here in Float, which is what makes thousands of paths affordable.
# The normals are drawn once per run and shared by every question asked of
# it: the success rate, the confident year, and every heatmap cell (common
# random numbers), so answers differ only by their inputs.
class RetirementPlan::MonteCarlo
  PERCENTILES = [ 10, 25, 50, 75, 90 ].freeze
  RETURN_STEPS = [ -0.02, -0.01, 0, 0.01, 0.02 ].freeze
  SAVINGS_STEPS = [ -0.10, -0.05, 0, 0.05, 0.10 ].freeze

  # Standard normals by the Box-Muller transform, two per pair of uniforms.
  def self.normals(rng, count)
    Array.new((count + 1) / 2) do
      u1 = 1.0 - rng.rand # (0, 1], so the log is finite
      u2 = rng.rand
      radius = Math.sqrt(-2.0 * Math.log(u1))
      [ radius * Math.cos(2 * Math::PI * u2), radius * Math.sin(2 * Math::PI * u2) ]
    end.flatten.first(count)
  end

  # Nearest-rank percentile: the smallest value with at least p% of the
  # values at or below it.
  def self.percentile(values, p)
    sorted = values.sort
    sorted[[ (p / 100.0 * sorted.size).ceil - 1, 0 ].max]
  end

  attr_reader :retirement_year, :volatility, :seed, :paths, :savings_rate

  def expected_annual_return
    @inputs.fetch(:expected_annual_return).to_d
  end

  def initialize(simulation_inputs:, retirement_year:, annual_income:, savings_rate:, volatility:, seed:, paths:)
    @inputs = simulation_inputs
    @retirement_year = retirement_year
    @annual_income = annual_income.to_d
    @savings_rate = savings_rate.to_d
    @volatility = volatility
    @sigma = volatility.to_f
    @seed = seed
    @paths = paths
  end

  def success_rate(retirement_year: @retirement_year)
    run(simulation(retirement_year: retirement_year))[:success_rate]
  end

  # The portfolio at the end of each year, in today's money, at each
  # percentile across the paths.
  def percentiles
    @percentiles ||= begin
      values = run(simulation, keep_values: true)[:values]
      deflators = (1..year_count).map { |n| (1 + base_simulation.inflation_rate.to_f)**n }

      PERCENTILES.to_h do |p|
        [ p, (0...year_count).map { |t| self.class.percentile(values.map { |path| path[t] }, p) / deflators[t] } ]
      end
    end
  end

  # The same draws with each path's retirement-year returns reordered worst
  # first: the same average return, the worst sequence.
  def stress_success_rate
    run(simulation, worst_first: true)[:success_rate]
  end

  # The first year whose success rate reaches `target`, or nil if none does
  # before the end age.
  def confident_year(target)
    target = target.to_f
    (first_year..last_year).detect { |year| success_rate(retirement_year: year) >= target }
  end

  # 5 x 5: rows step the expected return, columns the savings rate, both
  # ascending, each cell on the same draws.
  def heatmap
    RETURN_STEPS.map do |return_step|
      SAVINGS_STEPS.map do |savings_step|
        rate = (@savings_rate + savings_step.to_d).clamp(0, 1)
        sim = simulation(
          expected_annual_return: @inputs.fetch(:expected_annual_return).to_d + return_step.to_d,
          annual_contribution: @annual_income * rate
        )
        { return_step: return_step, savings_step: savings_step, success_rate: run(sim)[:success_rate] }
      end
    end
  end

  private
    def base_simulation
      @base_simulation ||= simulation
    end

    def simulation(retirement_year: @retirement_year, **overrides)
      RetirementPlan::Simulation.new(**@inputs.merge(overrides), retirement_year: retirement_year)
    end

    def first_year
      @inputs.fetch(:as_of).year
    end

    def last_year
      @inputs.fetch(:birth_year) + @inputs.fetch(:end_age)
    end

    def year_count
      last_year - first_year + 1
    end

    # One row of normals per path, drawn once from the seed.
    def draws
      @draws ||= begin
        flat = self.class.normals(Random.new(@seed), @paths * year_count)
        flat.each_slice(year_count).to_a
      end
    end

    def run(sim, keep_values: false, worst_first: false)
      flows = sim.yearly_flows.map { |c, w| [ c.to_f, w.to_f ] }
      base = 1 + sim.return_rate.to_f
      retired_from = sim.retirement_year - first_year
      survived = 0
      values = [] if keep_values

      draws.each do |z|
        growth = z.map { |zt| base * Math.exp(@sigma * zt) }
        if worst_first && retired_from.between?(0, year_count - 1)
          growth = growth[0...retired_from] + growth[retired_from..].sort
        end

        value = sim.current_assets.to_f
        lasted = true
        path_values = [] if keep_values

        flows.each_with_index do |(contribution, withdrawal), t|
          if withdrawal > value
            lasted = false
            value = 0.0
          else
            value -= withdrawal
          end
          value = value * growth[t] + contribution
          path_values << value if keep_values
        end

        survived += 1 if lasted
        values << path_values if keep_values
      end

      { success_rate: survived.fdiv(@paths), values: values }
    end
end
