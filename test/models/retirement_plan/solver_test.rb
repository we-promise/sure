require "test_helper"

class RetirementPlan::SolverTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 3, 15)
  Stream = RetirementPlan::Simulation::Stream

  # 0% return and no inflation, so every figure below is plain arithmetic.
  # Born 1976, so 50 in 2026 and the end age of 60 is 2036: retiring in year
  # Y means spending 10,000 a year for (2036 - Y + 1) years. Contributing
  # 10,000 a year until then, the portfolio at the start of year Y is
  # 20,000 + 10,000 × (Y - 2026). It lasts when that covers the years left:
  #   2029: 50,000 vs 8 years × 10,000 = 80,000  -> runs out
  #   2030: 60,000 vs 70,000                     -> runs out
  #   2031: 70,000 vs 60,000                     -> lasts
  test "the earliest year is the first whose retirement lasts to the end age" do
    result = solve(current_assets: 20_000)

    assert_equal 2031, result.retirement_year
    assert_equal 55, result.retirement_age
  end

  test "the year before the answer runs out, which is what makes it the earliest" do
    before = simulation(current_assets: 20_000, retirement_year: 2030)
    answer = simulation(current_assets: 20_000, retirement_year: 2031)

    assert_not before.survives?
    assert answer.survives?
  end

  test "a plan that can already retire gets this year" do
    result = solve(current_assets: 1_000_000)

    assert_equal AS_OF.year, result.retirement_year
  end

  test "a plan that never lasts gets no year, and the age the money runs out at the latest start" do
    result = solve(current_assets: 0, annual_contribution: 0)

    assert_nil result.retirement_year
    assert_equal 60, result.depletion_age
  end

  private
    def base
      {
        as_of: AS_OF, current_assets: 0, annual_contribution: 10_000, expected_annual_return: 0, inflation_rate: 0,
        streams: [ Stream.new(kind: "expense", annual_amount: 10_000) ], birth_year: 1976, end_age: 60
      }
    end

    def simulation(**overrides)
      RetirementPlan::Simulation.new(**base.merge(overrides))
    end

    def solve(**overrides)
      RetirementPlan::Solver.new(**base.merge(overrides)).call
    end
end
