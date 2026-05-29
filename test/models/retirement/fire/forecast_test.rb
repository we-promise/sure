require "test_helper"

class Retirement::Fire::ForecastTest < ActiveSupport::TestCase
  Forecast = Retirement::Fire::Forecast
  Inputs = Retirement::Fire::Inputs
  Payout = Retirement::Fire::Payout
  Adjustment = Retirement::Fire::Adjustment

  def inputs(**over)
    defaults = {
      current_age: 40, retire_age: 65, terminal_age: 95, real_return: 0.05,
      annual_savings: 0, annual_target_spend: 24_000, starting_portfolio: 0,
      retire_year: 2050, payouts: [], target_adjustments: []
    }
    Inputs.new(**defaults.merge(over))
  end

  def payout(**over)
    Payout.new(**{ kind: "state", shape: "monthly_for_life", tax_treatment: "custom_post_tax", start_age: 65, monthly_amount: 0 }.merge(over))
  end

  test "accumulation is deterministic (zero return-free check)" do
    result = Forecast.new(inputs(
      current_age: 64, retire_age: 65, terminal_age: 66,
      real_return: 0.10, annual_savings: 1000, starting_portfolio: 1000,
      annual_target_spend: 0
    )).call

    assert_equal [ [ 64, 1000 ], [ 65, 2100 ], [ 66, 2310 ] ], result.glide
    assert result.feasible
    assert_equal 2310, result.terminal_value
  end

  test "drawdown depletion is exact and flags shortfall" do
    result = Forecast.new(inputs(
      current_age: 65, retire_age: 65, terminal_age: 67,
      real_return: 0.0, starting_portfolio: 100, annual_target_spend: 60
    )).call

    assert_equal [ [ 65, 100 ], [ 66, 40 ], [ 67, 0 ] ], result.glide
    assert_not result.feasible
    assert_equal 66, result.money_lasts_to_age
    assert_equal 0, result.terminal_value
    last = result.income_by_year.last
    assert_equal 40, last[:drawdown]
    assert_equal 20, last[:shortfall]
    assert_includes result.warnings, "depletes_before_terminal"
  end

  test "a pension that fully covers spend means no drawdown" do
    result = Forecast.new(inputs(
      retire_age: 65, starting_portfolio: 0, annual_target_spend: 24_000,
      payouts: [ payout(kind: "state", start_age: 65, monthly_amount: 2000) ]
    )).call

    assert result.feasible
    assert result.lasts_past_terminal?
    first_draw = result.income_by_year.first
    assert_equal 24_000, first_draw[:state]
    assert_equal 0, first_draw[:drawdown]
  end

  test "tax reduces net pension income and widens the drawdown" do
    result = Forecast.new(inputs(
      retire_age: 65, starting_portfolio: 5_000_000, annual_target_spend: 24_000,
      payouts: [ payout(kind: "workplace", tax_treatment: "de_bav", start_age: 65, monthly_amount: 2000) ]
    )).call

    row = result.income_by_year.first
    assert_equal 17_760, row[:workplace]      # 24,000 gross * 0.74
    assert_equal 6_240, row[:drawdown]        # 24,000 - 17,760
  end

  test "a negative adjustment lowers the target spend from its age" do
    result = Forecast.new(inputs(
      retire_age: 65, starting_portfolio: 5_000_000, annual_target_spend: 24_000,
      target_adjustments: [ Adjustment.new(from_age: 65, to_age: nil, annual_amount: -12_000) ]
    )).call

    assert_equal 12_000, result.income_by_year.first[:drawdown]
  end

  test "coast_age is current_age when already over-funded" do
    result = Forecast.new(inputs(
      starting_portfolio: 10_000_000, annual_savings: 0, annual_target_spend: 24_000
    )).call

    assert_equal 40, result.coast_age
    assert result.feasible
  end

  test "infeasible plan has no coast age and warns" do
    result = Forecast.new(inputs(
      starting_portfolio: 0, annual_savings: 0, annual_target_spend: 100_000
    )).call

    assert_nil result.coast_age
    assert_not result.feasible
    assert_includes result.warnings, "infeasible_no_coast"
  end

  test "glide spans current_age to terminal_age inclusive" do
    result = Forecast.new(inputs(current_age: 30, terminal_age: 95)).call
    assert_equal 30, result.glide.first.first
    assert_equal 95, result.glide.last.first
    assert_equal 66, result.glide.length
  end
end
