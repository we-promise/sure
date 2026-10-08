require "test_helper"

class RetirementPlan::SimulationTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 3, 15)
  Stream = RetirementPlan::Simulation::Stream

  test "0% return and no inflation: each year adds the contribution and nothing compounds" do
    sim = simulation(expected_annual_return: 0, annual_contribution: 10_000)

    assert_equal [ 110_000, 120_000, 130_000 ], sim.rows.first(3).map(&:end_value)
  end

  test "5% return with no inflation matches the simple projection's hand-computed table to the cent" do
    sim = simulation(expected_annual_return: BigDecimal("0.05"), annual_contribution: 10_000)

    assert_equal %w[115000.0 130750.0 147287.5], sim.rows.first(3).map { |r| r.end_value.round(2).to_s("F") }
  end

  # 100,000 at 5%, a contribution of 10,000 that grows with 3% inflation:
  #   year 1: 100,000.00 × 1.05 + 10,000.00 = 115,000.00  → ÷ 1.03   = 111,650.49
  #   year 2: 115,000.00 × 1.05 + 10,300.00 = 131,050.00  → ÷ 1.0609 = 123,527.19
  #   year 3: 131,050.00 × 1.05 + 10,609.00 = 148,211.50  → ÷ 1.092727 = 135,634.52
  test "3% inflation matches a hand-computed table, nominal and in today's money" do
    sim = simulation(expected_annual_return: BigDecimal("0.05"), inflation_rate: BigDecimal("0.03"), annual_contribution: 10_000)
    rows = sim.rows.first(3)

    assert_equal %w[115000.0 131050.0 148211.5], rows.map { |r| r.end_value.round(2).to_s("F") }
    assert_equal %w[111650.49 123527.19 135634.52], rows.map { |r| r.end_value_real.round(2).to_s("F") }
  end

  test "a withdrawal comes out at the start of the year, before that year's growth" do
    sim = simulation(expected_annual_return: BigDecimal("0.05"), retirement_year: AS_OF.year,
                     streams: [ Stream.new(kind: "expense", annual_amount: 40_000) ])

    assert_equal BigDecimal("40000"), sim.rows.first.withdrawal
    assert_equal BigDecimal("63000"), sim.rows.first.end_value
  end

  test "before retirement nothing is withdrawn for spending; from the retirement year it is" do
    sim = simulation(retirement_year: AS_OF.year + 2, streams: [ Stream.new(kind: "expense", annual_amount: 1_000) ])

    assert_equal [ 0, 0, 1_000, 1_000 ], sim.rows.first(4).map(&:withdrawal)
    assert_equal [ 10_000, 10_000, 0, 0 ], sim.rows.first(4).map(&:contribution)
  end

  test "a pension is set against spending, and a surplus is reinvested rather than withdrawn as a negative" do
    sim = simulation(retirement_year: AS_OF.year, streams: [
      Stream.new(kind: "expense", annual_amount: 30_000),
      Stream.new(kind: "income", annual_amount: 10_000),
      Stream.new(kind: "income", annual_amount: 35_000, start_year: AS_OF.year + 1)
    ])

    assert_equal [ 20_000, 0 ], sim.rows.first(2).map(&:withdrawal)
    assert_equal [ 0, 15_000 ], sim.rows.first(2).map(&:contribution)
  end

  test "a one-off amount comes out in its year only, before or after retirement" do
    sim = simulation(retirement_year: AS_OF.year + 5,
                     streams: [ Stream.new(kind: "one_off", annual_amount: 25_000, start_year: AS_OF.year + 1) ])

    assert_equal [ 0, 25_000, 0 ], sim.rows.first(3).map(&:withdrawal)
  end

  test "a stream with an end year stops after that year" do
    sim = simulation(retirement_year: AS_OF.year,
                     streams: [ Stream.new(kind: "expense", annual_amount: 12_000, end_year: AS_OF.year + 1) ])

    assert_equal [ 12_000, 12_000, 0 ], sim.rows.first(3).map(&:withdrawal)
  end

  test "an indexed stream grows with inflation from today; an unindexed one does not" do
    sim = simulation(retirement_year: AS_OF.year, inflation_rate: BigDecimal("0.03"), streams: [
      Stream.new(kind: "expense", annual_amount: 10_000, indexed: true),
      Stream.new(kind: "expense", annual_amount: 5_000, indexed: false)
    ])

    assert_equal [ BigDecimal("15000"), BigDecimal("15300"), BigDecimal("15609") ], sim.rows.first(3).map(&:withdrawal)
  end

  test "the table runs to the end age, and the age is the year minus the birth year" do
    sim = simulation(birth_year: 1980, end_age: 90)

    assert_equal AS_OF.year, sim.rows.first.year
    assert_equal 2070, sim.rows.last.year
    assert_equal [ 46, 90 ], [ sim.rows.first.age, sim.rows.last.age ]
  end

  # 50,000 at 0% with 20,000 a year of spending from today: 30,000 after the
  # first year, 10,000 after the second, and the third year's 20,000 cannot be
  # met from the 10,000 left. The money runs out in the third year, at 48.
  test "the money runs out in the first year a withdrawal cannot be met, and the balance stays at zero" do
    sim = simulation(current_assets: 50_000, annual_contribution: 0, retirement_year: AS_OF.year, birth_year: 1980,
                     streams: [ Stream.new(kind: "expense", annual_amount: 20_000) ])

    assert_not sim.survives?
    assert_equal 48, sim.depletion_age
    assert_equal AS_OF.year + 2, sim.depletion_year
    assert_equal [ 30_000, 10_000, 0, 0 ], sim.rows.first(4).map(&:end_value)
  end

  test "a plan that never runs short survives, with no depletion age" do
    sim = simulation(current_assets: 1_000_000, retirement_year: AS_OF.year, birth_year: 1980,
                     streams: [ Stream.new(kind: "expense", annual_amount: 1_000) ])

    assert sim.survives?
    assert_nil sim.depletion_age
  end

  test "nothing in the engine reads the clock, the database or the current request" do
    source = Rails.root.glob("app/models/retirement_plan/{simulation,solver}.rb").map(&:read).join

    assert_no_match(/Date\.(current|today)|Time\.(current|now|zone)|Current\.|ActiveRecord|\.where\(|\.find/, source)
  end

  private
    def simulation(**overrides)
      RetirementPlan::Simulation.new(**{
        as_of: AS_OF,
        current_assets: 100_000,
        annual_contribution: 10_000,
        expected_annual_return: 0,
        inflation_rate: 0,
        streams: [],
        retirement_year: AS_OF.year + 100,
        birth_year: 1980,
        end_age: 90
      }.merge(overrides))
    end
end
