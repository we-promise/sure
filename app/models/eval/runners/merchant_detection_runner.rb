class Eval::Runners::MerchantDetectionRunner < Eval::Runners::Base
  BATCH_SIZE = 25  # Matches Provider::Openai limit
  FUZZY_MATCH_THRESHOLD = 0.8

  protected

    def process_samples
      all_samples = samples.to_a
      log_progress("Processing #{all_samples.size} samples in batches of #{BATCH_SIZE}")

      all_samples.each_slice(BATCH_SIZE).with_index do |batch, batch_idx|
        log_progress("Processing batch #{batch_idx + 1}/#{(all_samples.size.to_f / BATCH_SIZE).ceil}")
        process_batch(batch)
      end
    end

    def calculate_metrics
      Eval::Metrics::MerchantDetectionMetrics.new(eval_run).calculate
    end

  private

    def process_batch(batch_samples)
      # Build inputs for the provider
      transactions = batch_samples.map do |sample|
        sample.to_transaction_input.merge(id: sample.id)
      end

      # Get merchants from first sample's context (should be shared)
      # Symbolize keys since Provider::Openai::AutoMerchantDetector expects symbol keys
      merchants = batch_samples.first.merchants_context.map(&:deep_symbolize_keys)

      start_time = Time.current

      begin
        response = provider.auto_detect_merchants(
          transactions: transactions,
          user_merchants: merchants,
          model: model
        )

        latency_ms = ((Time.current - start_time) * 1000).to_i
        per_sample_latency = latency_ms / batch_samples.size

        if response.success?
          record_batch_results(batch_samples, response.data, per_sample_latency)
        else
          record_batch_errors(batch_samples, response.error, per_sample_latency)
        end
      rescue => e
        latency_ms = ((Time.current - start_time) * 1000).to_i
        per_sample_latency = latency_ms / batch_samples.size
        record_batch_errors(batch_samples, e, per_sample_latency)
      end
    end

    def record_batch_results(batch_samples, merchants_detected, per_sample_latency)
      batch_samples.each do |sample|
        # Find the merchant detection result for this sample
        detection = merchants_detected.find { |m| m.transaction_id.to_s == sample.id.to_s }

        actual_name = normalize_null(detection&.business_name)
        actual_url = normalize_null(detection&.business_url)

        expected_name = sample.expected_business_name
        expected_url = sample.expected_business_url

        # Evaluate correctness
        name_match = evaluate_name_match(actual_name, expected_name)
        url_match = evaluate_url_match(actual_url, expected_url)
        fuzzy_score = calculate_fuzzy_score(actual_name, expected_name)

        # Overall correct if both name and URL match expectations
        correct = name_match && url_match

        # Exact match requires both to be exactly equal
        exact_match = actual_name == expected_name && normalize_url(actual_url) == normalize_url(expected_url)

        record_result(
          sample: sample,
          actual_output: { "business_name" => actual_name, "business_url" => actual_url },
          correct: correct,
          exact_match: exact_match,
          fuzzy_score: fuzzy_score,
          null_expected: expected_name.nil? && expected_url.nil?,
          null_returned: actual_name.nil? && actual_url.nil?,
          latency_ms: per_sample_latency
        )
      end
    end

    def record_batch_errors(batch_samples, error, per_sample_latency)
      error_message = error.is_a?(Exception) ? error.message : error.to_s

      batch_samples.each do |sample|
        record_result(
          sample: sample,
          actual_output: { "error" => error_message },
          correct: false,
          exact_match: false,
          fuzzy_score: 0.0,
          null_expected: sample.expected_business_name.nil?,
          null_returned: true,
          latency_ms: per_sample_latency,
          metadata: { "error" => error_message }
        )
      end
    end

    def normalize_null(value)
      return nil if value.nil?
      return nil if value == "null"
      return nil if value.to_s.strip.empty?
      value
    end

    def evaluate_name_match(actual, expected)
      # Both null = correct
      return true if actual.nil? && expected.nil?
      # Expected null but got value = false positive
      return false if expected.nil? && actual.present?
      # Expected value but got null = false negative
      return false if actual.nil? && expected.present?
      # Use fuzzy matching for name comparison
      fuzzy_match?(actual, expected)
    end

    def evaluate_url_match(actual, expected)
      # Both null = correct
      return true if actual.nil? && expected.nil?
      # Expected null but got value = false positive
      return false if expected.nil? && actual.present?
      # Expected value but got null = false negative
      return false if actual.nil? && expected.present?
      # Normalize and compare URLs
      normalize_url(actual) == normalize_url(expected)
    end

    def normalize_url(url)
      return nil if url.nil?
      url.to_s.downcase
         .gsub(/^(https?:\/\/)?(www\.)?/, "")
         .chomp("/")
         .strip
    end

    def fuzzy_match?(actual, expected)
      return false if actual.nil? || expected.nil?
      calculate_fuzzy_score(actual, expected) >= FUZZY_MATCH_THRESHOLD
    end

    def calculate_fuzzy_score(actual, expected)
      return 1.0 if actual == expected
      return 0.0 if actual.nil? || expected.nil?

      # Simple Levenshtein distance-based similarity
      # Normalize strings for comparison
      a = actual.to_s.downcase.strip
      b = expected.to_s.downcase.strip

      return 1.0 if a == b

      # Calculate Levenshtein distance
      distance = levenshtein_distance(a, b)
      max_length = [ a.length, b.length ].max

      return 0.0 if max_length == 0

      # Convert distance to similarity score (0.0 to 1.0)
      (1.0 - (distance.to_f / max_length)).round(4)
    end

    def levenshtein_distance(s1, s2)
      m = s1.length
      n = s2.length

      return m if n == 0
      return n if m == 0

      # Create distance matrix
      d = Array.new(m + 1) { Array.new(n + 1) }

      (0..m).each { |i| d[i][0] = i }
      (0..n).each { |j| d[0][j] = j }

      (1..n).each do |j|
        (1..m).each do |i|
          cost = s1[i - 1] == s2[j - 1] ? 0 : 1
          d[i][j] = [
            d[i - 1][j] + 1,      # deletion
            d[i][j - 1] + 1,      # insertion
            d[i - 1][j - 1] + cost # substitution
          ].min
        end
      end

      d[m][n]
    end
end
