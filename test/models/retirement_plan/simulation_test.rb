require "test_helper"

class RetirementPlan::SimulationTest < ActiveSupport::TestCase
  # 1 January: the whole first year is still ahead, so the hand-computed
  # tables below count it in full. The tests on a later reference date say so.
  AS_OF = Date.new(2026, 1, 1)
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

  test "before retirement nothing is withdrawn for seeded spending; from the retirement year it is" do
    sim = simulation(retirement_year: AS_OF.year + 2, streams: [ Stream.new(kind: "expense", annual_amount: 1_000, seeded: true) ])

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

  test "a one-off amount comes out in its year only, before retirement" do
    sim = simulation(retirement_year: AS_OF.year + 5,
                     streams: [ Stream.new(kind: "one_off", annual_amount: 25_000, start_year: AS_OF.year + 1) ])

    assert_equal [ 0, 25_000, 0 ], sim.rows.first(3).map(&:withdrawal)
  end

  # Retired from this year, spending covered exactly by a pension, so the
  # one-off is the only flow: it must come out, not go back in as savings.
  test "a one-off in a retirement year is withdrawn, not reinvested" do
    sim = simulation(retirement_year: AS_OF.year, streams: [
      Stream.new(kind: "expense", annual_amount: 10_000),
      Stream.new(kind: "income", annual_amount: 10_000),
      Stream.new(kind: "one_off", annual_amount: 25_000, start_year: AS_OF.year + 1)
    ])

    assert_equal [ 0, 25_000, 0 ], sim.rows.first(3).map(&:withdrawal)
    assert_equal [ 0, 0, 0 ], sim.rows.first(3).map(&:contribution)
    assert_equal BigDecimal("75000"), sim.rows.second.end_value
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

  # 40,000 at 0% with 20,000 a year: the second year's withdrawal takes the
  # last 20,000, which is met, and only the third year's cannot be.
  test "a withdrawal that takes exactly what is left is met" do
    sim = simulation(current_assets: 40_000, annual_contribution: 0, retirement_year: AS_OF.year,
                     streams: [ Stream.new(kind: "expense", annual_amount: 20_000) ])

    assert_equal AS_OF.year + 2, sim.depletion_year
    assert_equal [ 20_000, 0 ], sim.rows.first(2).map(&:end_value)
  end

  test "a plan that never runs short survives, with no depletion age" do
    sim = simulation(current_assets: 1_000_000, retirement_year: AS_OF.year, birth_year: 1980,
                     streams: [ Stream.new(kind: "expense", annual_amount: 1_000) ])

    assert sim.survives?
    assert_nil sim.depletion_age
  end

  # Born 1935 with an end age of 90: the plan ended in 2025. With no years to
  # run, no withdrawal is ever tested, so `survives?` would answer true.
  test "an end-age year before the reference year is refused, and the end-age year itself is not" do
    assert_raises(ArgumentError) { simulation(birth_year: 1935, end_age: 90) }
    assert_equal [ AS_OF.year ], simulation(birth_year: 1936, end_age: 90).rows.map(&:year)
  end

  # The reference date is an argument: two runs on different days, with no
  # query and no request, must give the same rows and the same solved year.
  test "the simulation and solver read neither the clock, the database nor the current request" do
    Current.expects(:user).never
    Current.expects(:family).never
    streams = [ Stream.new(kind: "expense", annual_amount: 30_000), Stream.new(kind: "one_off", annual_amount: 5_000, start_year: 2030) ]
    inputs = { as_of: AS_OF, current_assets: 100_000, annual_contribution: 10_000, expected_annual_return: BigDecimal("0.05"),
               inflation_rate: BigDecimal("0.02"), streams: streams, birth_year: 1980, end_age: 90 }

    runs = [ Date.new(2026, 3, 1), Date.new(2031, 9, 30) ].map do |today|
      travel_to(today) do
        figures = nil
        assert_queries_count(0) do
          sim = RetirementPlan::Simulation.new(**inputs, retirement_year: 2040)
          figures = [ sim.rows, sim.survives?, sim.depletion_age, RetirementPlan::Solver.new(**inputs).call ]
        end
        figures
      end
    end

    assert_equal runs.first, runs.last
  end

  # --- The first year -------------------------------------------------------

  # From 2 July 2026, 183 of 2026's 365 days are left. At 0% the year adds
  # 10,000 x 183/365 = 5,013.70 of contribution, not a whole 10,000.
  test "the first year counts only the part of the year left from the reference date" do
    sim = simulation(as_of: Date.new(2026, 7, 2), annual_contribution: 10_000)

    assert_equal %w[105013.7 115013.7], sim.rows.first(2).map { |r| r.end_value.round(2).to_s("F") }
  end

  # 100,000 at 5% from 2 July: the first year grows by 1.05^(183/365).
  test "the first year's growth compounds over the part of the year left" do
    sim = simulation(as_of: Date.new(2026, 7, 2), annual_contribution: 0, expected_annual_return: BigDecimal("0.05"))

    assert_equal "102476.36", sim.rows.first.end_value.round(2).to_s("F")
    assert_equal "107600.17", sim.rows.second.end_value.round(2).to_s("F")
  end

  # Retired, spending 36,500 a year from 2 July: 18,300 of it falls in 2026.
  # A one-off is a single payment, so it comes out whole.
  test "spending in the first year is the part of the year left; a one-off is paid whole" do
    sim = simulation(as_of: Date.new(2026, 7, 2), retirement_year: 2026, streams: [
      Stream.new(kind: "expense", annual_amount: 36_500),
      Stream.new(kind: "one_off", annual_amount: 5_000)
    ])

    assert_equal "23300.0", sim.rows.first.withdrawal.round(2).to_s("F")
    assert_equal "36500.0", sim.rows.second.withdrawal.round(2).to_s("F")
  end

  # The reviewer's case: 100,000 with 10,000 a year at 7%. From 31 December
  # 2026 only that day is left of 2026, so 2027 ends where it does from
  # 1 January 2027, give or take a day's growth and contribution. Counting the
  # whole of 2026 put it at 135,490 against 117,000.
  test "a plan read on 31 December and on 1 January ends the next year within a day of each other" do
    inputs = { annual_contribution: 10_000, expected_annual_return: BigDecimal("0.07"), retirement_year: 2040 }
    dec31 = simulation(**inputs, as_of: Date.new(2026, 12, 31))
    jan1 = simulation(**inputs, as_of: Date.new(2027, 1, 1))

    assert_equal BigDecimal("117000"), jan1.rows.first.end_value
    assert_in_delta 117_000, dec31.rows.find { _1.year == 2027 }.end_value, 60
  end

  # The contribution is in today's money and grows from the reference date:
  # read on 31 December 2026, 2027's 10,000 has grown one day, 10,000 x
  # 1.03^(1/365) = 10,000.81, not a whole year to 10,300. Each later year
  # adds a whole year. The day left of 2026 saves 10,000 / 365 = 27.40, with
  # no inflation yet.
  test "the contribution grows with inflation from the reference date, not the first calendar year" do
    sim = simulation(as_of: Date.new(2026, 12, 31), annual_contribution: 10_000, inflation_rate: BigDecimal("0.03"))
    by_year = sim.rows.index_by(&:year)

    assert_equal "27.4", by_year[2026].contribution.round(2).to_s("F")
    assert_equal "10000.81", by_year[2027].contribution.round(2).to_s("F")
    assert_equal "10300.83", by_year[2028].contribution.round(2).to_s("F")
  end

  # In today's money the first year deflates by the part of the year left,
  # not a whole year: 100,000 at 0% with 3% inflation from 2 July.
  test "the first year's value in today's money deflates by the part of the year left" do
    sim = simulation(as_of: Date.new(2026, 7, 2), annual_contribution: 0, inflation_rate: BigDecimal("0.03"))

    assert_equal "98528.94", sim.rows.first.end_value_real.round(2).to_s("F")
  end

  # --- Streams before retirement ---------------------------------------------

  # An expense the user adds runs before retirement too: it comes out of
  # the 10,000 contribution, and what the contribution cannot cover comes out
  # of the portfolio. Income adds to the contribution.
  test "a manual expense or income before retirement moves the contribution" do
    sim = simulation(retirement_year: 2045, streams: [
      Stream.new(kind: "expense", annual_amount: 20_000, start_year: 2030, end_year: 2033),
      Stream.new(kind: "income", annual_amount: 12_000, start_year: 2028)
    ])
    by_year = sim.rows.index_by(&:year)

    assert_equal [ 10_000, 0 ], [ by_year[2027].contribution, by_year[2027].withdrawal ]
    assert_equal [ 22_000, 0 ], [ by_year[2028].contribution, by_year[2028].withdrawal ]
    assert_equal [ 2_000, 0 ], [ by_year[2030].contribution, by_year[2030].withdrawal ]
    assert_equal [ 22_000, 0 ], [ by_year[2034].contribution, by_year[2034].withdrawal ]
  end

  test "a manual expense larger than the contribution before retirement is drawn from the portfolio" do
    sim = simulation(retirement_year: 2045, streams: [ Stream.new(kind: "expense", annual_amount: 25_000, start_year: 2027, end_year: 2027) ])
    row = sim.rows.find { _1.year == 2027 }

    assert_equal [ 0, 15_000 ], [ row.contribution, row.withdrawal ]
  end

  # Seeded streams are today's living costs and loan repayments, which the
  # contribution is already what is left after paying.
  test "a seeded stream does not move the contribution before retirement" do
    sim = simulation(retirement_year: 2045, streams: [
      Stream.new(kind: "expense", annual_amount: 30_000, seeded: true),
      Stream.new(kind: "expense", annual_amount: 6_000, indexed: false, seeded: true)
    ])

    assert_equal [ 10_000, 10_000 ], sim.rows.first(2).map(&:contribution)
    assert_equal [ 0, 0 ], sim.rows.first(2).map(&:withdrawal)
  end

  # --- A stream's base year --------------------------------------------------

  # Entered as 10,000 in 2025's money and read in 2026 at 3% inflation, it is
  # 10,300 in 2026: the year since it was entered is not lost.
  test "an indexed stream grows from the year its amount is valued in" do
    sim = simulation(retirement_year: 2026, inflation_rate: BigDecimal("0.03"), streams: [
      Stream.new(kind: "expense", annual_amount: 10_000, base_year: 2025),
      Stream.new(kind: "expense", annual_amount: 1_000, base_year: 2025, indexed: false)
    ])

    assert_equal [ BigDecimal("11300"), BigDecimal("11609") ], sim.rows.first(2).map(&:withdrawal)
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
