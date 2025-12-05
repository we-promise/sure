class Eval::Metrics::CategorizationMetrics < Eval::Metrics::Base
  def calculate
    {
      accuracy: accuracy,
      exact_match_accuracy: exact_match_accuracy,
      alternative_match_count: alternative_match_count,
      precision: precision,
      recall: recall,
      f1_score: f1_score,
      null_accuracy: null_accuracy,
      hierarchical_accuracy: hierarchical_accuracy,
      samples_processed: total_count,
      samples_correct: correct_count,
      avg_latency_ms: avg_latency_ms,
      total_cost: total_cost,
      cost_per_sample: cost_per_sample,
      by_difficulty: metrics_by_difficulty,
      by_category: metrics_by_category
    }
  end

  private

    def exact_match_accuracy
      # Percentage of results that exactly match the primary expected category
      return 0.0 if total_count.zero?
      (results.where(exact_match: true).count.to_f / total_count * 100).round(2)
    end

    def alternative_match_count
      # Number of results that matched an alternative (but not primary) category
      results.where(alternative_match: true).count
    end

    def null_accuracy
      # Accuracy for samples where null was expected
      null_expected_results = results.where(null_expected: true)
      return 100.0 if null_expected_results.empty?

      correct = null_expected_results.where(null_returned: true).count
      total = null_expected_results.count

      (correct.to_f / total * 100).round(2)
    end

    def hierarchical_accuracy
      # Percentage of results that match at hierarchical level (including exact matches)
      return 0.0 if total_count.zero?
      (results.where(hierarchical_match: true).count.to_f / total_count * 100).round(2)
    end

    def precision
      # True positives / (True positives + False positives)
      # TP: Correct non-null predictions
      # FP: Incorrect non-null predictions (predicted wrong category)
      true_positives = results.where(correct: true, null_returned: false).count
      false_positives = results.where(correct: false, null_returned: false).count

      denominator = true_positives + false_positives
      return 0.0 if denominator.zero?

      (true_positives.to_f / denominator * 100).round(2)
    end

    def recall
      # True positives / (True positives + False negatives)
      # TP: Correct non-null predictions
      # FN: Incorrectly returned null when category was expected
      true_positives = results.where(correct: true, null_returned: false).count
      false_negatives = results.where(null_expected: false, null_returned: true).count

      denominator = true_positives + false_negatives
      return 0.0 if denominator.zero?

      (true_positives.to_f / denominator * 100).round(2)
    end

    def f1_score
      return 0.0 if precision.zero? || recall.zero?
      (2 * precision * recall / (precision + recall)).round(2)
    end

    def metrics_by_category
      # Group results by expected category and calculate accuracy
      category_metrics = {}

      results.includes(:sample).each do |result|
        expected = result.sample.expected_category_name || "null"

        category_metrics[expected] ||= { correct: 0, total: 0 }
        category_metrics[expected][:total] += 1
        category_metrics[expected][:correct] += 1 if result.correct
      end

      category_metrics.transform_values do |metrics|
        metrics.merge(
          accuracy: (metrics[:correct].to_f / metrics[:total] * 100).round(2)
        )
      end
    end
end
