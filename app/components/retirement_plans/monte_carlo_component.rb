# frozen_string_literal: true

# The Monte Carlo result on the planner page: the chance the money lasts, the
# stress test, the confident year in FIRE mode, and the grid over return and
# savings rate. Formatting only: the figures come from
# RetirementPlan#monte_carlo_result, through RetirementPlan::MonteCarloCache.
class RetirementPlans::MonteCarloComponent < ViewComponent::Base
  attr_reader :plan, :result

  def initialize(plan:, result:)
    @plan = plan
    @result = result
  end

  def fire?
    plan.mode == "fire"
  end

  def percent(rate)
    helpers.number_to_percentage(rate.to_f * 100, precision: 0)
  end

  def target_met?
    result[:success_rate] >= plan.success_target.to_f
  end

  def confident_age
    result[:confident_year] - plan.birth_year
  end

  # Savings steps that clamp to the same rate (a plan saving 5% or less has
  # two at 0%) ran the same inputs on the same draws, so each rate is shown
  # once.
  def heatmap_columns
    result[:heatmap].first.each_index.uniq { |i| savings_rate_for(result[:heatmap].first[i][:savings_step]) }
  end

  def return_label(row)
    helpers.number_to_percentage((result[:expected_annual_return].to_f + row.first[:return_step]) * 100, precision: 0)
  end

  def savings_label(column)
    helpers.number_to_percentage(savings_rate_for(result[:heatmap].first[column][:savings_step]) * 100, precision: 0)
  end

  def cell(row, column)
    rate = row[column][:success_rate]
    tag.span(percent(rate), class: rate >= plan.success_target.to_f ? "text-success" : "text-warning")
  end

  private
    def savings_rate_for(step)
      # Float bounds: clamp returns the bound itself, and an Integer 0 would
      # not match the 0.0 an unclamped step can land on.
      (result[:savings_rate].to_f + step).clamp(0.0, 1.0)
    end
end
