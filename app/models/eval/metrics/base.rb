class Eval::Metrics::Base
  attr_reader :eval_run

  def initialize(eval_run)
    @eval_run = eval_run
  end

  def calculate
    raise NotImplementedError, "Subclasses must implement #calculate"
  end

  protected

    def results
      @results ||= eval_run.results.includes(:sample)
    end

    def samples
      @samples ||= eval_run.dataset.samples
    end

    def total_count
      results.count
    end

    def correct_count
      results.where(correct: true).count
    end

    def incorrect_count
      results.where(correct: false).count
    end

    def accuracy
      return 0.0 if total_count.zero?
      (correct_count.to_f / total_count * 100).round(2)
    end

    # A provider outage, an expired API key or a stale model slug records every
    # sample as incorrect, which is indistinguishable from genuinely wrong
    # answers in the accuracy figure alone — a 404 reads as a plausible 0%.
    # Counting errored samples separately keeps a broken run from being mistaken
    # for a benchmark result.
    def error_count
      # Memoized because `results` is a relation, not a loaded collection —
      # error_rate and samples_errored would otherwise each re-query.
      @error_count ||= results.where("metadata->>'error' IS NOT NULL").count
    end

    def error_rate
      return 0.0 if total_count.zero?
      (error_count.to_f / total_count * 100).round(2)
    end

    # Whether the provider's stated confidence tracks how often it was right.
    # Absent for providers that report no confidence, which is a different thing
    # from being badly calibrated — see Eval::Metrics::Calibration.
    def calibration
      @calibration ||= Eval::Metrics::Calibration.new(eval_run)
    end

    def avg_latency_ms
      return nil if total_count.zero?
      results.average(:latency_ms)&.round(0)
    end

    # nil when no result reported a cost at all, which is NOT the same as a run
    # that cost nothing. `sum` returns 0 over all-NULL, so without this guard an
    # uninstrumented provider reports as free — the OpenAI path never populates
    # `cost`, and TypeSafe's native API returns token counts without a settled
    # price (only the OpenRouter gateway prices each call). Reporting those as
    # $0.00 would make the cheapest-provider comparison pick whichever provider
    # measures cost least.
    def cost_reported?
      return @cost_reported if defined?(@cost_reported)
      @cost_reported = results.where.not(cost: nil).exists?
    end

    def total_cost
      return nil unless cost_reported?
      results.sum(:cost)&.to_f&.round(6)
    end

    def cost_per_sample
      return nil if total_count.zero?
      return nil unless cost_reported?
      (total_cost / total_count).round(6)
    end

    def metrics_by_difficulty
      %w[easy medium hard edge_case].index_with do |difficulty|
        difficulty_results = results.joins(:sample).where(eval_samples: { difficulty: difficulty })
        next nil if difficulty_results.empty?

        correct = difficulty_results.where(correct: true).count
        total = difficulty_results.count

        {
          count: total,
          correct: correct,
          accuracy: (correct.to_f / total * 100).round(2)
        }
      end.compact
    end
end
