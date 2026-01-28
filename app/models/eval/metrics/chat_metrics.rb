class Eval::Metrics::ChatMetrics < Eval::Metrics::Base
  def calculate
    {
      accuracy: accuracy,
      function_selection_accuracy: function_selection_accuracy,
      parameter_accuracy: parameter_accuracy,
      response_relevance: response_relevance,
      exact_match_rate: exact_match_rate,
      error_rate: error_rate,
      avg_functions_per_response: avg_functions_per_response,
      samples_processed: total_count,
      samples_correct: correct_count,
      avg_latency_ms: avg_latency_ms,
      total_cost: total_cost,
      cost_per_sample: cost_per_sample,
      by_difficulty: metrics_by_difficulty,
      by_function: metrics_by_function
    }
  end

  private

    def function_selection_accuracy
      # Percentage of samples where correct functions were called
      valid_results = results.where.not("metadata->>'error' IS NOT NULL")
      return 0.0 if valid_results.empty?

      correct = valid_results.count do |r|
        r.metadata.dig("function_selection_correct") == true
      end

      (correct.to_f / valid_results.count * 100).round(2)
    end

    def parameter_accuracy
      # Average parameter accuracy across all samples
      valid_results = results.where.not("metadata->>'error' IS NOT NULL")
      return 0.0 if valid_results.empty?

      scores = valid_results.map do |r|
        r.metadata.dig("parameter_accuracy") || 0.0
      end

      (scores.sum / scores.size * 100).round(2)
    end

    def response_relevance
      # Percentage of samples where response contained expected keywords
      valid_results = results.where.not("metadata->>'error' IS NOT NULL")
      return 0.0 if valid_results.empty?

      correct = valid_results.count do |r|
        # If no keywords expected, consider it relevant
        expected_keywords = r.metadata.dig("expected_keywords") || []
        expected_keywords.empty? || r.metadata.dig("response_keywords_found") == true
      end

      (correct.to_f / valid_results.count * 100).round(2)
    end

    def exact_match_rate
      return 0.0 if total_count.zero?
      (results.where(exact_match: true).count.to_f / total_count * 100).round(2)
    end

    def error_rate
      return 0.0 if total_count.zero?

      errors = results.count do |r|
        r.metadata.dig("error").present? || r.actual_output.dig("error").present?
      end

      (errors.to_f / total_count * 100).round(2)
    end

    def avg_functions_per_response
      valid_results = results.where.not("actual_output->>'error' IS NOT NULL")
      return 0.0 if valid_results.empty?

      total_functions = valid_results.sum do |r|
        functions = r.actual_output.dig("functions") || []
        functions.size
      end

      (total_functions.to_f / valid_results.count).round(2)
    end

    def metrics_by_function
      # Group results by expected function and calculate accuracy
      function_metrics = {}

      results.includes(:sample).each do |result|
        expected_functions = result.sample.expected_functions

        expected_functions.each do |func|
          name = func["name"]
          next if name.nil?

          function_metrics[name] ||= { correct: 0, total: 0, param_accuracy_sum: 0 }
          function_metrics[name][:total] += 1

          # Check if this specific function was called correctly
          actual_functions = result.actual_output.dig("functions") || []
          if actual_functions.any? { |f| normalize_name(f["name"]) == normalize_name(name) }
            function_metrics[name][:correct] += 1
            function_metrics[name][:param_accuracy_sum] += (result.metadata.dig("parameter_accuracy") || 0.0)
          end
        end
      end

      function_metrics.transform_values do |metrics|
        {
          total: metrics[:total],
          correct: metrics[:correct],
          accuracy: (metrics[:correct].to_f / metrics[:total] * 100).round(2),
          avg_param_accuracy: metrics[:correct] > 0 ? (metrics[:param_accuracy_sum] / metrics[:correct] * 100).round(2) : 0.0
        }
      end
    end

    def normalize_name(name)
      return nil if name.nil?
      name.to_s.underscore.downcase
    end
end
