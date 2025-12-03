class Eval::Runners::CategorizationRunner < Eval::Runners::Base
  DEFAULT_BATCH_SIZE = 25  # Matches Provider::Openai limit

  protected

    def process_samples
      all_samples = samples.to_a
      batch_size = effective_batch_size
      log_progress("Processing #{all_samples.size} samples in batches of #{batch_size}")

      all_samples.each_slice(batch_size).with_index do |batch, batch_idx|
        log_progress("Processing batch #{batch_idx + 1}/#{(all_samples.size.to_f / batch_size).ceil}")
        process_batch(batch)
      end
    end

    # Use smaller batches for custom providers (local LLMs) to reduce context length
    def effective_batch_size
      eval_run.provider_config["batch_size"]&.to_i || DEFAULT_BATCH_SIZE
    end

    # Get JSON mode from provider config (optional override)
    # Valid values: "strict", "json_object", "none"
    def json_mode
      eval_run.provider_config["json_mode"]
    end

    def calculate_metrics
      Eval::Metrics::CategorizationMetrics.new(eval_run).calculate
    end

  private

    def process_batch(batch_samples)
      # Build inputs for the provider
      transactions = batch_samples.map do |sample|
        sample.to_transaction_input.merge(id: sample.id)
      end

      # Get categories from first sample's context (should be shared)
      # Symbolize keys since Provider::Openai::AutoCategorizer expects symbol keys
      categories = batch_samples.first.categories_context.map(&:deep_symbolize_keys)

      start_time = Time.current

      begin
        response = provider.auto_categorize(
          transactions: transactions,
          user_categories: categories,
          model: model,
          json_mode: json_mode
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

    def record_batch_results(batch_samples, categorizations, per_sample_latency)
      batch_samples.each do |sample|
        # Find the categorization result for this sample
        categorization = categorizations.find { |c| c.transaction_id.to_s == sample.id.to_s }
        actual_category = categorization&.category_name

        # Normalize "null" string to nil
        actual_category = nil if actual_category == "null"

        expected_category = sample.expected_category_name

        # Evaluate correctness
        correct = evaluate_correctness(actual_category, expected_category)
        exact_match = actual_category == expected_category
        hierarchical = evaluate_hierarchical_match(actual_category, expected_category, sample)

        record_result(
          sample: sample,
          actual_output: { "category_name" => actual_category },
          correct: correct,
          exact_match: exact_match,
          hierarchical_match: hierarchical,
          null_expected: expected_category.nil?,
          null_returned: actual_category.nil?,
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
          hierarchical_match: false,
          null_expected: sample.expected_category_name.nil?,
          null_returned: true,
          latency_ms: per_sample_latency,
          metadata: { "error" => error_message }
        )
      end
    end

    def evaluate_correctness(actual, expected)
      # Both null = correct
      return true if actual.nil? && expected.nil?
      # Expected null but got value = incorrect
      return false if expected.nil? && actual.present?
      # Expected value but got null = incorrect
      return false if actual.nil? && expected.present?
      # Compare values
      actual == expected
    end

    def evaluate_hierarchical_match(actual, expected, sample)
      return false if actual.nil? || expected.nil?
      return true if actual == expected

      # Check if actual matches parent of expected category
      categories = sample.categories_context

      # Find the expected category
      expected_cat = categories.find { |c| c["name"] == expected }
      return false unless expected_cat

      # If expected has a parent, check if actual matches the parent
      if expected_cat["parent_id"]
        parent = categories.find { |c| c["id"].to_s == expected_cat["parent_id"].to_s }
        return parent && parent["name"] == actual
      end

      # Also check if actual is a subcategory of expected (reverse direction)
      actual_cat = categories.find { |c| c["name"] == actual }
      return false unless actual_cat

      if actual_cat["parent_id"]
        parent = categories.find { |c| c["id"].to_s == actual_cat["parent_id"].to_s }
        return parent && parent["name"] == expected
      end

      false
    end
end
