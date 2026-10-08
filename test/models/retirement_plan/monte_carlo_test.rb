require "test_helper"

class RetirementPlan::MonteCarloTest < ActiveSupport::TestCase
  AS_OF = Date.new(2026, 3, 15)
  Stream = RetirementPlan::Simulation::Stream

  # Born 1980, end age 70 (2050). 400,000 at 5%, 20,000 a year saved until
  # 2036, then 30,000 a year of spending, indexed at 2%.
  def inputs(**overrides)
    {
      as_of: AS_OF, current_assets: 400_000, annual_contribution: 20_000,
      expected_annual_return: BigDecimal("0.05"), inflation_rate: BigDecimal("0.02"),
      streams: [ Stream.new(kind: "expense", annual_amount: 30_000) ],
      birth_year: 1980, end_age: 70
    }.merge(overrides)
  end

  def monte_carlo(volatility: BigDecimal("0.12"), seed: 42, paths: 500, retirement_year: 2036, **overrides)
    RetirementPlan::MonteCarlo.new(
      simulation_inputs: inputs(**overrides), retirement_year: retirement_year,
      annual_income: 50_000, savings_rate: BigDecimal("0.4"),
      volatility: volatility, seed: seed, paths: paths
    )
  end

  test "with no volatility every path is the deterministic projection, to the cent" do
    deterministic = RetirementPlan::Simulation.new(**inputs, retirement_year: 2036)
    mc = monte_carlo(volatility: 0)

    expected = deterministic.rows.map { |row| row.end_value_real.round(2) }
    RetirementPlan::MonteCarlo::PERCENTILES.each do |p|
      assert_equal expected, mc.percentiles.fetch(p).map { |v| v.to_d.round(2) }, "p#{p}"
    end
    assert_equal (deterministic.survives? ? 1.0 : 0.0), mc.success_rate
  end

  test "the same seed gives the same result, and a different seed a different one" do
    a = monte_carlo(seed: 7)
    b = monte_carlo(seed: 7)
    c = monte_carlo(seed: 8)

    assert_equal [ a.success_rate, a.percentiles ], [ b.success_rate, b.percentiles ]
    assert_not_equal a.percentiles.fetch(10), c.percentiles.fetch(10)
  end

  test "the normal draws have mean 0 and standard deviation 1" do
    draws = RetirementPlan::MonteCarlo.normals(Random.new(3), 20_000)
    mean = draws.sum / draws.size
    sd = Math.sqrt(draws.sum { |z| (z - mean)**2 } / draws.size)

    assert_in_delta 0, mean, 0.02
    assert_in_delta 1, sd, 0.02
  end

  # 61,000 a year of spending is just inside what the deterministic path can
  # meet (it lasts up to 61,473), so about half the paths fall short once
  # returns vary.
  test "the success rate is the share of paths that last, so a plan that only just lasts on expected returns is a coin flip" do
    tight = monte_carlo(streams: [ Stream.new(kind: "expense", annual_amount: 61_000) ])
    deterministic = RetirementPlan::Simulation.new(**inputs(streams: [ Stream.new(kind: "expense", annual_amount: 61_000) ]), retirement_year: 2036)

    assert deterministic.survives?, "the fixture must just last on expected returns"
    assert_operator tight.success_rate, :>, 0.3
    assert_operator tight.success_rate, :<, 0.7
  end

  test "a percentile is the smallest value with at least that share at or below it" do
    values = (1..10).to_a.shuffle(random: Random.new(1))

    assert_equal [ 1, 3, 5, 8, 9 ], RetirementPlan::MonteCarlo::PERCENTILES.map { |p| RetirementPlan::MonteCarlo.percentile(values, p) }
  end

  test "the percentiles are in order every year" do
    mc = monte_carlo
    p10, p25, p50, p75, p90 = RetirementPlan::MonteCarlo::PERCENTILES.map { |p| mc.percentiles.fetch(p) }

    p10.each_index do |i|
      assert_operator p10[i], :<=, p25[i]
      assert_operator p25[i], :<=, p50[i]
      assert_operator p50[i], :<=, p75[i]
      assert_operator p75[i], :<=, p90[i]
    end
  end

  # With no contributions or spending, the median of a product of log-normal
  # growth factors is the product of their medians, so after 20 years the
  # median path is the deterministic one: 100,000 × 1.05^20. A mean-based
  # parameterisation would sit about 13% lower (exp(-20 × 0.12² / 2)).
  test "the median path is the expected-returns path" do
    mc = monte_carlo(paths: 2_000, current_assets: 100_000, annual_contribution: 0, streams: [], inflation_rate: 0,
                     birth_year: 1986, end_age: 60, retirement_year: 2100)
    expected = 100_000 * 1.05**20

    assert_in_delta expected, mc.percentiles.fetch(50)[19], expected * 0.03
  end

  test "the worst-first ordering of the same returns never succeeds more often" do
    mc = monte_carlo(streams: [ Stream.new(kind: "expense", annual_amount: 61_000) ])

    assert_operator mc.stress_success_rate, :<, mc.success_rate
  end

  test "the confident year is the first whose success reaches the target, and the year before falls short" do
    mc = monte_carlo(paths: 1_000)
    year = mc.confident_year(BigDecimal("0.9"))

    assert year, "the fixture must reach 90% before the end age"
    assert_operator mc.success_rate(retirement_year: year), :>=, 0.9
    assert_operator mc.success_rate(retirement_year: year - 1), :<, 0.9
  end

  test "a year whose success rate equals the target exactly is confident" do
    mc = monte_carlo(paths: 1_000)
    year = mc.confident_year(BigDecimal("0.9"))

    assert_equal year, mc.confident_year(mc.success_rate(retirement_year: year))
  end

  test "a plan already at the target retires this year" do
    mc = monte_carlo(current_assets: 50_000_000)

    assert_equal AS_OF.year, mc.confident_year(BigDecimal("0.9"))
  end

  test "the heatmap never lowers success for a higher return or savings rate, and its centre is the plain success rate" do
    mc = monte_carlo(streams: [ Stream.new(kind: "expense", annual_amount: 61_000) ])
    grid = mc.heatmap

    assert_equal 5, grid.size
    assert_equal mc.success_rate, grid[2][2][:success_rate]
    grid.each { |row| row.each_cons(2) { |a, b| assert_operator a[:success_rate], :<=, b[:success_rate] } }
    grid.transpose.each { |column| column.each_cons(2) { |a, b| assert_operator a[:success_rate], :<=, b[:success_rate] } }
    assert_operator grid[2][0][:success_rate], :<, grid[2][4][:success_rate], "saving more must help this tight plan"
    assert_operator grid[0][2][:success_rate], :<, grid[4][2][:success_rate], "a higher return must help this tight plan"
  end

  test "nothing in the Monte Carlo engine reads the clock, the database or the current request" do
    source = Rails.root.join("app/models/retirement_plan/monte_carlo.rb").read

    assert_no_match(/Date\.(current|today)|Time\.(current|now|zone)|Current\.|ActiveRecord|\.where\(|\.find/, source)
  end
end
