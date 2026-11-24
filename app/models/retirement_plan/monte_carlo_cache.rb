# A plan's Monte Carlo result, cached under a digest of every input the run
# reads.
#
# The run is computed inline, on the planner's own lazy frame request, rather
# than in a background job, so the cache can be best-effort: a store that is
# per-process or null (as in development) just runs it again. The page around
# it renders without waiting. On a fast machine a typical plan takes 0.6 to
# 0.8 seconds; the worst case, a FIRE plan from age 30 to 95 where no year
# reaches the confidence target, about 1.8.
class RetirementPlan::MonteCarloCache
  # Part of the key: raise it when the result's shape or the engine changes,
  # so a result cached by older code is not read back.
  VERSION = 1
  EXPIRES_IN = 1.day

  class << self
    # Nil, and nothing cached, when the plan has nothing to run.
    def fetch(plan, as_of:)
      Rails.cache.fetch(key(plan, as_of: as_of), expires_in: EXPIRES_IN, skip_nil: true) do
        result(plan, as_of: as_of)
      end
    end

    # RetirementPlan#monte_carlo_result without the percentile paths, which
    # the page does not draw and which cost a further full run.
    def result(plan, as_of:)
      run = plan.monte_carlo(as_of: as_of)
      return nil if run.nil?

      {
        as_of: as_of, retirement_year: run.retirement_year, success_rate: run.success_rate,
        stress_success_rate: run.stress_success_rate,
        confident_year: (run.confident_year(plan.success_target) if plan.mode == "fire"),
        heatmap: run.heatmap, expected_annual_return: run.expected_annual_return, savings_rate: run.savings_rate
      }
    end

    # Every input the run reads, so a changed setting, stream, balance or
    # spending figure is a new key. Streams are converted at `as_of`'s rate,
    # which the date in the key pins; one left out for want of a rate joins
    # the run when the rate arrives, so the count left out is an input too.
    def key(plan, as_of:)
      projection = plan.projection(as_of: as_of)
      funding = plan.birth_year && plan.simulation(as_of: as_of, retirement_year: plan.birth_year + plan.end_age)
      fingerprint = {
        paths: RetirementPlan::MONTE_CARLO_PATHS, seed: plan.monte_carlo_seed, as_of: as_of.iso8601,
        settings: plan.attributes.slice(*%w[mode retirement_date birth_year end_age expected_annual_return inflation_rate
                                            savings_rate safe_withdrawal_rate return_volatility success_target]),
        income: projection.annual_income, expenses: projection.annual_expenses,
        funding: funding&.current_assets,
        streams: plan.streams.order(:id).map { |s| s.attributes.slice(*%w[kind annual_amount currency start_year end_year indexed]) },
        unconverted_streams: plan.unconverted_stream_count(as_of: as_of)
      }
      "retirement_plan/monte_carlo/v#{VERSION}/#{Digest::SHA256.hexdigest(fingerprint.to_json)}"
    end
  end
end
