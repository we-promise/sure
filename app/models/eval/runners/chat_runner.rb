class Eval::Runners::ChatRunner < Eval::Runners::Base
  # Chat samples are processed one at a time (not batched)
  # because each has unique context and function calling requirements

  protected

    def process_samples
      all_samples = samples.to_a
      log_progress("Processing #{all_samples.size} chat samples")

      all_samples.each_with_index do |sample, idx|
        log_progress("Processing sample #{idx + 1}/#{all_samples.size}")
        process_sample(sample)
      end
    end

    def calculate_metrics
      Eval::Metrics::ChatMetrics.new(eval_run).calculate
    end

  private

    def process_sample(sample)
      prompt = sample.chat_prompt
      start_time = Time.current

      begin
        response = provider.chat_response(
          prompt,
          model: model,
          instructions: build_instructions,
          functions: build_function_definitions
        )

        latency_ms = ((Time.current - start_time) * 1000).to_i

        if response.success?
          record_chat_result(sample, response.data, latency_ms)
        else
          record_error_result(sample, response.error, latency_ms)
        end
      rescue => e
        latency_ms = ((Time.current - start_time) * 1000).to_i
        record_error_result(sample, e, latency_ms)
      end
    end

    def record_chat_result(sample, chat_response, latency_ms)
      # Extract function calls from response
      actual_functions = extract_functions_from_response(chat_response)

      # Extract response text
      response_text = extract_response_text(chat_response)

      # Evaluate function calling accuracy
      expected_functions = sample.expected_functions
      function_match = evaluate_function_match(actual_functions, expected_functions)

      # Evaluate response content
      expected_keywords = sample.expected_response_contains
      response_match = evaluate_response_contains(response_text, expected_keywords)

      # Overall correctness: functions are correct AND response contains expected keywords
      correct = function_match[:correct] && response_match

      record_result(
        sample: sample,
        actual_output: {
          "functions" => actual_functions,
          "response_text" => response_text,
          "function_match_details" => function_match
        },
        correct: correct,
        exact_match: function_match[:exact_match],
        latency_ms: latency_ms,
        metadata: {
          "function_selection_correct" => function_match[:selection_correct],
          "parameter_accuracy" => function_match[:parameter_accuracy],
          "response_keywords_found" => response_match,
          "expected_functions" => expected_functions,
          "expected_keywords" => expected_keywords
        }
      )
    end

    def record_error_result(sample, error, latency_ms)
      error_message = error.is_a?(Exception) ? error.message : error.to_s

      record_result(
        sample: sample,
        actual_output: { "error" => error_message },
        correct: false,
        exact_match: false,
        latency_ms: latency_ms,
        metadata: { "error" => error_message }
      )
    end

    def extract_functions_from_response(chat_response)
      # ChatResponse has function_requests array
      function_requests = chat_response.function_requests || []

      function_requests.map do |req|
        {
          "name" => req.function_name,
          "params" => parse_function_args(req.function_args)
        }
      end
    end

    def parse_function_args(args)
      return {} if args.nil?
      return args if args.is_a?(Hash)
      JSON.parse(args)
    rescue JSON::ParserError
      {}
    end

    def extract_response_text(chat_response)
      # ChatResponse has messages array with output_text
      messages = chat_response.messages || []
      messages.map(&:output_text).compact.join("\n")
    end

    def evaluate_function_match(actual_functions, expected_functions)
      return { correct: true, exact_match: true, selection_correct: true, parameter_accuracy: 1.0 } if expected_functions.empty? && actual_functions.empty?
      return { correct: false, exact_match: false, selection_correct: false, parameter_accuracy: 0.0 } if expected_functions.empty? && actual_functions.any?

      # Check function selection accuracy
      expected_names = expected_functions.map { |f| normalize_function_name(f["name"]) }.compact
      actual_names = actual_functions.map { |f| normalize_function_name(f["name"]) }.compact

      selection_correct = expected_names.all? { |name| actual_names.include?(name) }

      # Check parameter accuracy for matched functions
      param_scores = []
      expected_functions.each do |expected_func|
        expected_name = normalize_function_name(expected_func["name"])
        actual_func = actual_functions.find { |f| normalize_function_name(f["name"]) == expected_name }

        if actual_func
          param_score = evaluate_parameters(actual_func["params"], expected_func["params"] || {})
          param_scores << param_score
        else
          param_scores << 0.0
        end
      end

      parameter_accuracy = param_scores.empty? ? 0.0 : (param_scores.sum / param_scores.size).round(4)

      # Exact match requires same functions with same parameters
      exact_match = selection_correct && parameter_accuracy == 1.0

      # Correct if all expected functions were called (parameters don't have to be exact)
      correct = selection_correct

      {
        correct: correct,
        exact_match: exact_match,
        selection_correct: selection_correct,
        parameter_accuracy: parameter_accuracy
      }
    end

    def normalize_function_name(name)
      return nil if name.nil?
      # Convert to snake_case and downcase
      name.to_s.underscore.downcase
    end

    def evaluate_parameters(actual_params, expected_params)
      return 1.0 if expected_params.empty?
      return 0.0 if actual_params.nil?

      actual_params = actual_params.stringify_keys
      expected_params = expected_params.stringify_keys

      matches = 0
      total = expected_params.size

      expected_params.each do |key, expected_value|
        actual_value = actual_params[key]

        if values_match?(actual_value, expected_value)
          matches += 1
        end
      end

      (matches.to_f / total).round(4)
    end

    def values_match?(actual, expected)
      return true if actual == expected
      return true if actual.to_s.downcase == expected.to_s.downcase

      # For arrays, check if all expected values are present
      if expected.is_a?(Array) && actual.is_a?(Array)
        expected_normalized = expected.map { |v| v.to_s.downcase }
        actual_normalized = actual.map { |v| v.to_s.downcase }
        return expected_normalized.all? { |v| actual_normalized.include?(v) }
      end

      # For dates, try to parse and compare
      if expected.to_s =~ /^\d{4}-\d{2}-\d{2}$/
        begin
          expected_date = Date.parse(expected.to_s)
          actual_date = Date.parse(actual.to_s)
          return expected_date == actual_date
        rescue
          # Not valid dates, fall through
        end
      end

      false
    end

    def evaluate_response_contains(response_text, expected_keywords)
      return true if expected_keywords.empty?
      return false if response_text.nil? || response_text.empty?

      normalized_response = response_text.downcase

      expected_keywords.all? do |keyword|
        normalized_response.include?(keyword.to_s.downcase)
      end
    end

    def build_instructions
      # Simple instructions for evaluation - we don't have a real user/family context
      <<~PROMPT
      You are a financial assistant helping users understand their financial data.
      Use the functions available to answer questions about accounts, transactions, and financial statements.
      Today's date is #{Date.current}.
    PROMPT
    end

    def build_function_definitions
      # Return the function definitions that the chat would normally have
      [
        build_function_definition("get_transactions", "Get paginated transactions with optional filters"),
        build_function_definition("get_accounts", "Get all accounts with balances and historical data"),
        build_function_definition("get_balance_sheet", "Get current net worth, assets, and liabilities"),
        build_function_definition("get_income_statement", "Get income and expenses by category for a period")
      ]
    end

    def build_function_definition(name, description)
      {
        name: name,
        description: description,
        params_schema: { type: "object", properties: {}, additionalProperties: true },
        strict: false
      }
    end
end
