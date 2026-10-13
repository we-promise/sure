require "test_helper"

# What the Monte Carlo run is built from.
class RetirementPlan::MonteCarloInputsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  AS_OF = Date.new(2026, 3, 15)

  setup do
    @family = families(:dylan_family)
    @member = users(:family_member)
    RetirementPlan.where(user: @member).delete_all
    AccountShare.where(user: @member).delete_all
    account = Account.create!(family: @family, owner: @member, accountable: Depository.new,
                              name: "Checking #{SecureRandom.hex(3)}", currency: "USD", balance: 400_000)
    Balance.create!(account: account, date: AS_OF, balance: 400_000, currency: "USD")
    @plan = RetirementPlan.create!(user: @member, birth_year: 1980, end_age: 85, retirement_date: Date.new(2040, 1, 1),
                                   expected_annual_return: BigDecimal("0.05"))
    @plan.streams.create!(kind: "expense", name: "Living costs", annual_amount: 30_000)
  end

  test "the run uses the plan's own volatility, a seed fixed by the plan, and the plan's retirement year" do
    @plan.update!(return_volatility: BigDecimal("0.2")) # not the column default, so a hard-coded default fails
    mc = @plan.monte_carlo(as_of: AS_OF)

    assert_equal RetirementPlan::MONTE_CARLO_PATHS, mc.paths
    assert_equal 2040, mc.retirement_year
    assert_equal BigDecimal("0.2"), mc.volatility
    assert_equal @plan.monte_carlo_seed, mc.seed
    assert_equal @plan.monte_carlo_seed, RetirementPlan.find(@plan.id).monte_carlo_seed, "the seed is stable across loads"
    assert_not_equal @plan.monte_carlo_seed, RetirementPlan.create!(user: users(:family_admin)).monte_carlo_seed
  ensure
    RetirementPlan.where(user: users(:family_admin)).delete_all
  end

  test "in FIRE mode the run retires in the expected-returns year" do
    @plan.update!(mode: "fire")

    assert_equal @plan.solve(as_of: AS_OF).retirement_year, @plan.monte_carlo(as_of: AS_OF).retirement_year
  end

  # The seed is the plan's id, so an unsaved plan has no run, and nothing
  # should be computed to find that out: in FIRE mode the year comes from
  # the solver, which reads the user's accounts.
  test "an unsaved plan has no run, and the solver never runs for it" do
    plan = RetirementPlan.new(user: users(:family_admin), birth_year: 1980, mode: "fire")
    RetirementPlan::Solver.expects(:new).never

    assert_nil plan.monte_carlo(as_of: AS_OF)
    assert_nil plan.monte_carlo_result(as_of: AS_OF)
  end

  # On the same terms as #simulation. Born 1940 with an end age of 85 the
  # plan ended in 2025; born 2027 it has not begun; retiring in 2066 is
  # after the end-age year 2065.
  test "a plan with no years to plan, or retiring after its end age, has no run in either mode" do
    %w[traditional fire].each do |mode|
      [ 1940, 2027 ].each do |birth_year|
        @plan.update!(mode: mode, birth_year: birth_year)
        assert_nil @plan.monte_carlo(as_of: AS_OF), "#{mode}, born #{birth_year}"
        assert_nil @plan.monte_carlo_result(as_of: AS_OF), "#{mode}, born #{birth_year}"
      end
    end

    @plan.update!(mode: "traditional", birth_year: 1980, retirement_date: Date.new(2066, 1, 1))
    assert_nil @plan.monte_carlo(as_of: AS_OF), "retiring after the end age"

    @plan.update!(retirement_date: Date.new(2065, 1, 1))
    assert_equal 2065, @plan.monte_carlo(as_of: AS_OF).retirement_year, "retiring in the end-age year"
  end

  test "the result carries the run's figures as plain values" do
    result = @plan.monte_carlo_result(as_of: AS_OF)

    assert_equal @plan.monte_carlo(as_of: AS_OF).success_rate, result[:success_rate]
    assert_equal RetirementPlan::MonteCarlo::PERCENTILES, result[:percentiles].keys
    assert_equal 5, result[:heatmap].size
  end

  # The confident year is a search over retirement years, each a full run of
  # every path, and only FIRE mode shows it.
  test "outside FIRE mode the result has no confident year and the search never runs" do
    RetirementPlan::MonteCarlo.any_instance.expects(:confident_year).never

    assert_nil @plan.monte_carlo_result(as_of: AS_OF)[:confident_year]
  end

  test "in FIRE mode the result carries the confident year for the plan's target" do
    @plan.update!(mode: "fire", success_target: BigDecimal("0.85"))
    RetirementPlan::MonteCarlo.any_instance.expects(:confident_year).with(BigDecimal("0.85")).returns(2039).once

    assert_equal 2039, @plan.monte_carlo_result(as_of: AS_OF)[:confident_year]
  end
end
