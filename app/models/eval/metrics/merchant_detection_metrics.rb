class Eval::Metrics::MerchantDetectionMetrics < Eval::Metrics::Base
  FUZZY_MATCH_THRESHOLD = 0.8

  def calculate
    {
      accuracy: accuracy,
      name_accuracy: name_accuracy,
      fuzzy_name_accuracy: fuzzy_name_accuracy,
      url_accuracy: url_accuracy,
      false_positive_rate: false_positive_rate,
      false_negative_rate: false_negative_rate,
      samples_processed: total_count,
      samples_correct: correct_count,
      avg_latency_ms: avg_latency_ms,
      total_cost: total_cost,
      cost_per_sample: cost_per_sample,
      avg_fuzzy_score: avg_fuzzy_score,
      by_difficulty: metrics_by_difficulty
    }
  end

  private

    def name_accuracy
      # Exact name match accuracy for non-null expected names
      name_results = results.includes(:sample).select do |r|
        r.sample.expected_business_name.present?
      end

      return 100.0 if name_results.empty?

      correct = name_results.count do |r|
        actual = r.actual_output.dig("business_name") || r.actual_output["business_name"]
        expected = r.sample.expected_business_name
        actual == expected
      end

      (correct.to_f / name_results.size * 100).round(2)
    end

    def fuzzy_name_accuracy
      # Fuzzy name match accuracy (using fuzzy_score >= threshold)
      name_results = results.includes(:sample).select do |r|
        r.sample.expected_business_name.present?
      end

      return 100.0 if name_results.empty?

      correct = name_results.count do |r|
        (r.fuzzy_score || 0) >= FUZZY_MATCH_THRESHOLD
      end

      (correct.to_f / name_results.size * 100).round(2)
    end

    def url_accuracy
      # URL match accuracy for non-null expected URLs
      url_results = results.includes(:sample).select do |r|
        r.sample.expected_business_url.present?
      end

      return 100.0 if url_results.empty?

      correct = url_results.count do |r|
        actual = r.actual_output.dig("business_url") || r.actual_output["business_url"]
        expected = r.sample.expected_business_url
        normalize_url(actual) == normalize_url(expected)
      end

      (correct.to_f / url_results.size * 100).round(2)
    end

    def false_positive_rate
      # Rate of returning a merchant when null was expected
      null_expected_results = results.where(null_expected: true)
      return 0.0 if null_expected_results.empty?

      false_positives = null_expected_results.where(null_returned: false).count

      (false_positives.to_f / null_expected_results.count * 100).round(2)
    end

    def false_negative_rate
      # Rate of returning null when a merchant was expected
      merchant_expected_results = results.where(null_expected: false)
      return 0.0 if merchant_expected_results.empty?

      false_negatives = merchant_expected_results.where(null_returned: true).count

      (false_negatives.to_f / merchant_expected_results.count * 100).round(2)
    end

    def avg_fuzzy_score
      scores = results.where.not(fuzzy_score: nil).pluck(:fuzzy_score)
      return nil if scores.empty?

      (scores.sum / scores.size).round(4)
    end

    def normalize_url(url)
      return nil if url.nil?
      url.to_s.downcase
         .gsub(/^(https?:\/\/)?(www\.)?/, "")
         .chomp("/")
         .strip
    end
end
