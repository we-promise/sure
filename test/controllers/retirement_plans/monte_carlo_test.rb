require "test_helper"

# The Monte Carlo section: a lazy frame on the planner page, run inline by
# its own request and cached.
class RetirementPlans::MonteCarloTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    RetirementPlan.where(user: [ @user, users(:family_member) ]).delete_all
    sign_in @user
    ensure_tailwind_build
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @plan = RetirementPlan.create!(user: @user, birth_year: 1980, end_age: 90, retirement_date: Date.new(2045, 1, 1),
                                   success_target: BigDecimal("0.9"))
  end

  def result(success_rate: 0.93, confident_year: 2041, savings_rate: BigDecimal("0.2"))
    grid = RetirementPlan::MonteCarlo::RETURN_STEPS.map do |r|
      RetirementPlan::MonteCarlo::SAVINGS_STEPS.map { |s| { return_step: r, savings_step: s, success_rate: 0.5 } }
    end
    {
      as_of: Date.current, retirement_year: 2045, success_rate: success_rate, stress_success_rate: 0.71,
      confident_year: confident_year, percentiles: RetirementPlan::MonteCarlo::PERCENTILES.index_with { [ 1.0, 2.0 ] },
      heatmap: grid, expected_annual_return: BigDecimal("0.05"), savings_rate: savings_rate
    }
  end

  # The same plan is the same key, so each result is shown from a cleared cache.
  def frame_with(**options)
    Rails.cache.clear
    RetirementPlan.any_instance.stubs(:monte_carlo_result).returns(result(**options))
    get monte_carlo_retirement_plan_url
  end

  def heatmap_labels
    css_select("#retirement-plan-heatmap thead th").drop(1).map { |th| th.text.strip }
  end

  test "the page holds a lazy frame for the run and runs nothing itself" do
    RetirementPlan.any_instance.expects(:monte_carlo_result).never
    RetirementPlan::MonteCarlo.expects(:new).never

    get retirement_plan_url

    assert_select "turbo-frame#retirement-plan-monte-carlo-frame[loading='lazy'][src='#{monte_carlo_retirement_plan_path}']"
    assert_select "[data-success-rate]", count: 0
  end

  test "the frame shows the run's result" do
    get monte_carlo_retirement_plan_url

    assert_response :success
    assert_select "turbo-frame#retirement-plan-monte-carlo-frame #retirement-plan-monte-carlo [data-success-rate]"
    assert_select "#retirement-plan-heatmap tbody tr", count: 5
  end

  test "a cached result is shown again without running" do
    RetirementPlan.any_instance.expects(:monte_carlo_result).once.returns(result)

    2.times { get monte_carlo_retirement_plan_url }

    assert_select "[data-success-rate='0.93']"
  end

  test "without a saved plan of their own the frame is not found, whoever else has one" do
    RetirementPlan.create!(user: users(:family_member), birth_year: 1980, retirement_date: Date.new(2045, 1, 1))
    @plan.destroy!

    get monte_carlo_retirement_plan_url

    assert_response :not_found
  end

  test "a plan that cannot be simulated has no section, and its frame says so" do
    @plan.update!(birth_year: nil)

    get retirement_plan_url
    assert_select "#retirement-plan-monte-carlo-frame", count: 0

    get monte_carlo_retirement_plan_url
    assert_select "[data-monte-carlo-unavailable]"
  end

  test "savings steps that clamp to the same rate show as one heatmap column" do
    frame_with(savings_rate: BigDecimal("0.03"))

    assert_equal [ "0%", "3%", "8%", "13%" ], heatmap_labels
    assert_select "#retirement-plan-heatmap tbody tr:first-child td", count: 4
  end

  # Clamping returns the bound itself, so at exactly 5% the step to 0% and
  # the step clamped to 0 must still read as one rate; the same at the top.
  test "a savings step that lands exactly on a bound is merged with the clamped one" do
    frame_with(savings_rate: BigDecimal("0.05"))
    assert_equal [ "0%", "5%", "10%", "15%" ], heatmap_labels

    frame_with(savings_rate: BigDecimal("0.95"))
    assert_equal [ "85%", "90%", "95%", "100%" ], heatmap_labels
  end

  test "a savings rate clear of zero keeps all five heatmap columns" do
    frame_with

    assert_equal [ "10%", "15%", "20%", "25%", "30%" ], heatmap_labels
  end

  test "in FIRE mode the confident year is shown, or that no year reaches the target" do
    @plan.update!(mode: "fire")
    frame_with
    assert_select "[data-confident-year='2041']"

    frame_with(confident_year: nil)
    assert_select "[data-confident-year='none']"
  end

  test "the traditional mode shows no confident year" do
    frame_with

    assert_select "[data-confident-year]", count: 0
  end

  test "a user without preview access is turned away from the frame before anything runs" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    RetirementPlan.any_instance.expects(:monte_carlo_result).never

    get monte_carlo_retirement_plan_url

    assert_redirected_to root_path
  end
end
