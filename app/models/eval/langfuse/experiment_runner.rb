class Eval::Langfuse::ExperimentRunner
  attr_reader :dataset, :model, :provider, :client, :provider_config

  BATCH_SIZE = 25

  def initialize(dataset, model:, provider: "openai", client: nil, provider_config: {})
    @dataset = dataset
    @model = model
    @provider = provider
    @client = client || Eval::Langfuse::Client.new
    @provider_config = provider_config
  end

  def run(run_name: nil)
    @run_name = run_name || generate_run_name

    Rails.logger.info("[Langfuse Experiment] Starting experiment '#{@run_name}'")
    Rails.logger.info("[Langfuse Experiment] Dataset: #{dataset.name} (#{dataset.sample_count} samples)")
    Rails.logger.info("[Langfuse Experiment] Model: #{model}")

    # Ensure dataset exists in Langfuse
    ensure_dataset_exported

    # Get dataset items from Langfuse
    items = fetch_langfuse_items

    # Run the experiment
    results = process_items(items)

    # Calculate and report metrics
    metrics = calculate_metrics(results)

    Rails.logger.info("[Langfuse Experiment] Experiment '#{@run_name}' complete")
    Rails.logger.info("[Langfuse Experiment] Accuracy: #{metrics[:accuracy]}%")

    {
      run_name: @run_name,
      dataset_name: langfuse_dataset_name,
      model: model,
      samples_processed: results.size,
      metrics: metrics
    }
  end

  private

    def generate_run_name
      "#{dataset.name}_#{model.gsub('/', '_')}_#{Time.current.strftime('%Y%m%d_%H%M%S')}"
    end

    def langfuse_dataset_name
      "eval_#{dataset.name}"
    end

    def ensure_dataset_exported
      exporter = Eval::Langfuse::DatasetExporter.new(dataset, client: client)
      exporter.export
    end

    def fetch_langfuse_items
      items = []
      page = 1

      loop do
        response = client.get_dataset_items(dataset_name: langfuse_dataset_name, page: page, limit: 50)
        batch = response["data"] || []
        items.concat(batch)

        break if batch.size < 50

        page += 1
      end

      Rails.logger.info("[Langfuse Experiment] Fetched #{items.size} items from Langfuse")
      items
    end

    def process_items(items)
      results = []

      items.each_slice(BATCH_SIZE).with_index do |batch, batch_idx|
        Rails.logger.info("[Langfuse Experiment] Processing batch #{batch_idx + 1}/#{(items.size.to_f / BATCH_SIZE).ceil}")

        batch_results = process_batch(batch)
        results.concat(batch_results)
      end

      results
    end

    def process_batch(items)
      case dataset.eval_type
      when "categorization"
        process_categorization_batch(items)
      when "merchant_detection"
        process_merchant_detection_batch(items)
      when "chat"
        process_chat_batch(items)
      else
        raise "Unsupported eval type: #{dataset.eval_type}"
      end
    end

    def process_categorization_batch(items)
      transactions = items.map do |item|
        input = item["input"]
        txn = input["transaction"] || input
        txn.deep_symbolize_keys.merge(id: item["id"])
      end

      categories = items.first.dig("input", "categories") || []
      categories = categories.map(&:deep_symbolize_keys)

      # Determine effective JSON mode for this batch
      # If the batch has many expected nulls, force strict mode to prevent false retries
      effective_json_mode = json_mode_for_batch(items)

      start_time = Time.current

      response = llm_provider.auto_categorize(
        transactions: transactions,
        user_categories: categories,
        model: model,
        json_mode: effective_json_mode
      )

      latency_ms = ((Time.current - start_time) * 1000).to_i

      if response.success?
        items.map do |item|
          categorization = response.data.find { |c| c.transaction_id.to_s == item["id"].to_s }
          actual_category = normalize_null(categorization&.category_name)
          expected_category = item.dig("expectedOutput", "category_name")

          correct = actual_category == expected_category
          score_value = correct ? 1.0 : 0.0

          # Create trace and score in Langfuse
          trace_id = create_trace_for_item(item, actual_category, latency_ms)
          score_result(trace_id, item["id"], score_value, correct, actual_category, expected_category)

          {
            item_id: item["id"],
            expected: expected_category,
            actual: actual_category,
            correct: correct,
            latency_ms: latency_ms / items.size
          }
        end
      else
        handle_batch_error(items, response.error)
      end
    rescue => e
      handle_batch_error(items, e)
    end

    def process_merchant_detection_batch(items)
      transactions = items.map do |item|
        input = item["input"]
        txn = input["transaction"] || input
        txn.deep_symbolize_keys.merge(id: item["id"])
      end

      merchants = items.first.dig("input", "merchants") || []
      merchants = merchants.map(&:deep_symbolize_keys)

      start_time = Time.current

      response = llm_provider.auto_detect_merchants(
        transactions: transactions,
        user_merchants: merchants,
        model: model
      )

      latency_ms = ((Time.current - start_time) * 1000).to_i

      if response.success?
        items.map do |item|
          detection = response.data.find { |m| m.transaction_id.to_s == item["id"].to_s }
          actual_name = normalize_null(detection&.business_name)
          actual_url = normalize_null(detection&.business_url)
          expected_name = item.dig("expectedOutput", "business_name")
          expected_url = item.dig("expectedOutput", "business_url")

          name_match = actual_name == expected_name
          url_match = normalize_url(actual_url) == normalize_url(expected_url)
          correct = name_match && url_match
          score_value = correct ? 1.0 : 0.0

          # Create trace and score in Langfuse
          actual_output = { business_name: actual_name, business_url: actual_url }
          trace_id = create_trace_for_item(item, actual_output, latency_ms)
          score_result(trace_id, item["id"], score_value, correct, actual_output, item["expectedOutput"])

          {
            item_id: item["id"],
            expected: { name: expected_name, url: expected_url },
            actual: { name: actual_name, url: actual_url },
            correct: correct,
            latency_ms: latency_ms / items.size
          }
        end
      else
        handle_batch_error(items, response.error)
      end
    rescue => e
      handle_batch_error(items, e)
    end

    def process_chat_batch(items)
      # Chat is processed one at a time due to function calling complexity
      items.map do |item|
        process_chat_item(item)
      end
    end

    def process_chat_item(item)
      prompt = item.dig("input", "prompt")
      expected_functions = item.dig("expectedOutput", "functions") || []

      start_time = Time.current

      response = llm_provider.chat_response(
        prompt,
        model: model,
        instructions: "You are a helpful personal finance assistant.",
        functions: build_available_functions
      )

      latency_ms = ((Time.current - start_time) * 1000).to_i

      actual_functions = extract_function_calls(response)
      correct = evaluate_function_match(actual_functions, expected_functions)
      score_value = correct ? 1.0 : 0.0

      # Create trace and score in Langfuse
      trace_id = create_trace_for_item(item, { functions: actual_functions }, latency_ms)
      score_result(trace_id, item["id"], score_value, correct, actual_functions, expected_functions)

      {
        item_id: item["id"],
        expected: expected_functions,
        actual: actual_functions,
        correct: correct,
        latency_ms: latency_ms
      }
    rescue => e
      handle_item_error(item, e)
    end

    def create_trace_for_item(item, output, latency_ms)
      trace_id = client.create_trace(
        name: "#{dataset.eval_type}_eval",
        input: item["input"],
        output: output,
        metadata: {
          run_name: @run_name,
          model: model,
          latency_ms: latency_ms,
          dataset_item_id: item["id"]
        }
      )

      Rails.logger.debug("[Langfuse Experiment] Created trace #{trace_id} for item #{item['id']}")
      trace_id
    end

    def score_result(trace_id, item_id, score_value, correct, actual, expected)
      return unless trace_id

      # Score the accuracy
      client.create_score(
        trace_id: trace_id,
        name: "accuracy",
        value: score_value,
        comment: correct ? "Correct" : "Expected: #{expected.inspect}, Got: #{actual.inspect}"
      )

      # Link to dataset run
      client.create_dataset_run_item(
        run_name: @run_name,
        dataset_item_id: item_id,
        trace_id: trace_id,
        metadata: {
          correct: correct,
          actual: actual,
          expected: expected
        }
      )
    rescue => e
      Rails.logger.warn("[Langfuse Experiment] Failed to score item #{item_id}: #{e.message}")
    end

    def handle_batch_error(items, error)
      error_message = error.is_a?(Exception) ? error.message : error.to_s
      Rails.logger.error("[Langfuse Experiment] Batch error: #{error_message}")

      items.map do |item|
        {
          item_id: item["id"],
          expected: item["expectedOutput"],
          actual: { error: error_message },
          correct: false,
          latency_ms: 0
        }
      end
    end

    def handle_item_error(item, error)
      Rails.logger.error("[Langfuse Experiment] Item #{item['id']} error: #{error.message}")

      {
        item_id: item["id"],
        expected: item["expectedOutput"],
        actual: { error: error.message },
        correct: false,
        latency_ms: 0
      }
    end

    def calculate_metrics(results)
      total = results.size

      # Guard against empty results to avoid division by zero
      if total.zero?
        return {
          accuracy: 0.0,
          total: 0,
          correct: 0,
          incorrect: 0,
          avg_latency_ms: 0
        }
      end

      correct = results.count { |r| r[:correct] }
      avg_latency = results.sum { |r| r[:latency_ms] } / total.to_f

      {
        accuracy: (correct.to_f / total * 100).round(2),
        total: total,
        correct: correct,
        incorrect: total - correct,
        avg_latency_ms: avg_latency.round(0)
      }
    end

    def llm_provider
      @llm_provider ||= build_provider
    end

    def build_provider
      case provider
      when "openai"
        access_token = provider_config[:access_token] ||
                       ENV["OPENAI_ACCESS_TOKEN"] ||
                       Setting.openai_access_token

        raise "OpenAI access token not configured" unless access_token.present?

        uri_base = provider_config[:uri_base] ||
                   ENV["OPENAI_URI_BASE"] ||
                   Setting.openai_uri_base

        Provider::Openai.new(access_token, uri_base: uri_base, model: model)
      else
        raise "Unsupported provider: #{provider}"
      end
    end

    # Determine the effective JSON mode for a batch based on expected null ratio
    # This prevents the auto-categorizer from incorrectly retrying when many nulls are expected
    def json_mode_for_batch(items)
      # If a specific mode is configured (not "auto"), always use it
      configured_mode = provider_config[:json_mode]
      return configured_mode if configured_mode.present? && configured_mode != "auto"

      # Calculate expected null ratio for this batch
      expected_null_count = items.count { |item| item.dig("expectedOutput", "category_name").nil? }
      expected_null_ratio = expected_null_count.to_f / items.size

      # If >50% of the batch is expected to return null, force strict mode
      # This matches the AUTO_MODE_NULL_THRESHOLD in the auto-categorizer
      # and prevents unnecessary retries when nulls are legitimate
      if expected_null_ratio > 0.5
        Rails.logger.info("[Langfuse Experiment] Batch has #{(expected_null_ratio * 100).round}% expected nulls, forcing strict mode")
        "strict"
      else
        # Use auto mode - let the auto-categorizer decide
        "auto"
      end
    end

    def normalize_null(value)
      return nil if value.nil?
      return nil if value == "null"
      return nil if value.to_s.strip.empty?
      value
    end

    def normalize_url(url)
      return nil if url.nil?
      url.to_s.downcase
         .gsub(/^(https?:\/\/)?(www\.)?/, "")
         .chomp("/")
         .strip
    end

    def build_available_functions
      # Simplified function definitions for chat eval
      [
        {
          name: "get_accounts",
          description: "Get user's financial accounts",
          params_schema: { type: "object", properties: {}, required: [] }
        },
        {
          name: "get_transactions",
          description: "Get transactions with optional filters",
          params_schema: {
            type: "object",
            properties: {
              account_id: { type: "string" },
              start_date: { type: "string" },
              end_date: { type: "string" },
              category: { type: "string" }
            }
          }
        },
        {
          name: "get_balance_summary",
          description: "Get balance summary across accounts",
          params_schema: { type: "object", properties: {} }
        },
        {
          name: "get_spending_by_category",
          description: "Get spending breakdown by category",
          params_schema: {
            type: "object",
            properties: {
              start_date: { type: "string" },
              end_date: { type: "string" }
            }
          }
        }
      ]
    end

    def extract_function_calls(response)
      return [] unless response.respond_to?(:messages)

      response.messages.flat_map do |msg|
        next [] unless msg.respond_to?(:function_calls)
        msg.function_calls.map do |fc|
          { name: fc.name, arguments: fc.arguments }
        end
      end.compact
    end

    def evaluate_function_match(actual, expected)
      return true if expected.empty? && actual.empty?
      return false if expected.empty? != actual.empty?

      expected_names = expected.map { |f| f["name"] || f[:name] }.sort
      actual_names = actual.map { |f| f["name"] || f[:name] }.sort

      expected_names == actual_names
    end
end
