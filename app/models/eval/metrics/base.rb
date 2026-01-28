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

    def avg_latency_ms
      return nil if total_count.zero?
      results.average(:latency_ms)&.round(0)
    end

    def total_cost
      results.sum(:cost)&.to_f&.round(6)
    end

    def cost_per_sample
      return nil if total_count.zero?
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
