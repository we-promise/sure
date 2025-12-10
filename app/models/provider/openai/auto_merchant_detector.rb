class Provider::Openai::AutoMerchantDetector
  include Provider::Openai::Concerns::UsageRecorder

  # JSON response format modes for custom providers
  # - "strict": Use strict JSON schema (requires full OpenAI API compatibility)
  # - "json_object": Use json_object response format (broader compatibility)
  # - "none": No response format constraint (maximum compatibility with local LLMs)
  # - "auto": Try strict first, fall back to none if poor results
  JSON_MODE_STRICT = "strict"
  JSON_MODE_OBJECT = "json_object"
  JSON_MODE_NONE = "none"
  JSON_MODE_AUTO = "auto"

  # Threshold for auto mode: if more than this percentage returns null, retry with none mode
  AUTO_MODE_NULL_THRESHOLD = 0.5

  attr_reader :client, :model, :transactions, :user_merchants, :custom_provider, :langfuse_trace, :family, :json_mode

  def initialize(client, model: "", transactions:, user_merchants:, custom_provider: false, langfuse_trace: nil, family: nil, json_mode: nil)
    @client = client
    @model = model
    @transactions = transactions
    @user_merchants = user_merchants
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
    @json_mode = json_mode || default_json_mode
  end

  VALID_JSON_MODES = [ JSON_MODE_STRICT, JSON_MODE_OBJECT, JSON_MODE_NONE, JSON_MODE_AUTO ].freeze

  # Determine default JSON mode based on configuration hierarchy:
  # 1. Environment variable (LLM_JSON_MODE) - highest priority, for testing/override
  # 2. Setting.openai_json_mode - user-configured in app settings
  # 3. Default: auto mode (recommended for all providers)
  #
  # Mode descriptions:
  # - "auto": Tries strict first, falls back to none if >50% fail (recommended default)
  # - "strict": Best for thinking models (qwen-thinking, deepseek-reasoner) - skips verbose <think> tags
  # - "none": Best for non-thinking models (gpt-oss, llama, mistral) - allows reasoning in output
  # - "json_object": Middle ground, broader compatibility than strict
  def default_json_mode
    # 1. Check environment variable first (allows runtime override for testing)
    env_mode = ENV["LLM_JSON_MODE"]
    return env_mode if env_mode.present? && VALID_JSON_MODES.include?(env_mode)

    # 2. Check app settings (user-configured)
    setting_mode = Setting.openai_json_mode
    return setting_mode if setting_mode.present? && VALID_JSON_MODES.include?(setting_mode)

    # 3. Default: auto mode for all providers (tries strict first, falls back to none if needed)
    JSON_MODE_AUTO
  end

  def auto_detect_merchants
    if custom_provider
      auto_detect_merchants_openai_generic
    else
      auto_detect_merchants_openai_native
    end
  end

  def instructions
    if custom_provider
      simple_instructions
    else
      detailed_instructions
    end
  end

  # Simplified instructions for smaller/local LLMs
  def simple_instructions
    <<~INSTRUCTIONS.strip_heredoc
      Detect business names and websites from transaction descriptions. Return JSON only.

      Rules:
      1. Match transaction_id exactly from input
      2. Return business_name and business_url for known businesses
      3. Return "null" for both if uncertain or generic (e.g. "Paycheck", "Local diner")
      4. Don't include "www." in URLs (use "amazon.com" not "www.amazon.com")
      5. Favor "null" over guessing - only return values if 80%+ confident

      Example output format:
      {"merchants": [{"transaction_id": "txn_001", "business_name": "Amazon", "business_url": "amazon.com"}]}
    INSTRUCTIONS
  end

  # Detailed instructions for larger models like GPT-4
  def detailed_instructions
    <<~INSTRUCTIONS.strip_heredoc
      You are an assistant to a consumer personal finance app.

      Closely follow ALL the rules below while auto-detecting business names and website URLs:

      - Return 1 result per transaction
      - Correlate each transaction by ID (transaction_id)
      - Do not include the subdomain in the business_url (i.e. "amazon.com" not "www.amazon.com")
      - User merchants are considered "manual" user-generated merchants and should only be used in 100% clear cases
      - Be slightly pessimistic.  We favor returning "null" over returning a false positive.
      - NEVER return a name or URL for generic transaction names (e.g. "Paycheck", "Laundromat", "Grocery store", "Local diner")

      Determining a value:

      - First attempt to determine the name + URL from your knowledge of global businesses
      - If no certain match, attempt to match one of the user-provided merchants
      - If no match, return "null"

      Example 1 (known business):

      ```
      Transaction name: "Some Amazon purchases"

      Result:
      - business_name: "Amazon"
      - business_url: "amazon.com"
      ```

      Example 2 (generic business):

      ```
      Transaction name: "local diner"

      Result:
      - business_name: null
      - business_url: null
      ```
    INSTRUCTIONS
  end

  private

    def auto_detect_merchants_openai_native
      span = langfuse_trace&.span(name: "auto_detect_merchants_api_call", input: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        transactions: transactions,
        user_merchants: user_merchants
      })

      response = client.responses.create(parameters: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        input: [ { role: "developer", content: developer_message } ],
        text: {
          format: {
            type: "json_schema",
            name: "auto_detect_personal_finance_merchants",
            strict: true,
            schema: json_schema
          }
        },
        instructions: instructions
      })

      Rails.logger.info("Tokens used to auto-detect merchants: #{response.dig("usage", "total_tokens")}")

      merchants = extract_merchants_native(response)
      result = build_response(merchants)

      record_usage(
        model.presence || Provider::Openai::DEFAULT_MODEL,
        response.dig("usage"),
        operation: "auto_detect_merchants",
        metadata: {
          transaction_count: transactions.size,
          merchant_count: user_merchants.size
        }
      )

      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def auto_detect_merchants_openai_generic
      if json_mode == JSON_MODE_AUTO
        auto_detect_merchants_with_auto_mode
      else
        auto_detect_merchants_with_mode(json_mode)
      end
    rescue Faraday::BadRequestError => e
      # If strict mode fails (HTTP 400), fall back to none mode
      # This handles providers that don't support json_schema response format
      if json_mode == JSON_MODE_STRICT || json_mode == JSON_MODE_AUTO
        Rails.logger.warn("Strict JSON mode failed, falling back to none mode: #{e.message}")
        auto_detect_merchants_with_mode(JSON_MODE_NONE)
      else
        raise
      end
    end

    # Auto mode: try strict first, fall back to none if too many nulls or missing results
    def auto_detect_merchants_with_auto_mode
      result = auto_detect_merchants_with_mode(JSON_MODE_STRICT)

      # Check if too many nulls OR missing results were returned
      # Models that can't reason in strict mode often:
      # 1. Return null for everything, OR
      # 2. Simply omit transactions they can't detect (returning fewer results than input)
      null_count = result.count { |r| r.business_name.nil? || r.business_name == "null" }
      missing_count = transactions.size - result.size
      failed_count = null_count + missing_count
      failed_ratio = transactions.size > 0 ? failed_count.to_f / transactions.size : 0.0

      if failed_ratio > AUTO_MODE_NULL_THRESHOLD
        Rails.logger.info("Auto mode: #{(failed_ratio * 100).round}% failed (#{null_count} nulls, #{missing_count} missing) in strict mode, retrying with none mode")
        auto_detect_merchants_with_mode(JSON_MODE_NONE)
      else
        result
      end
    end

    def auto_detect_merchants_with_mode(mode)
      span = langfuse_trace&.span(name: "auto_detect_merchants_api_call", input: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        transactions: transactions,
        user_merchants: user_merchants,
        json_mode: mode
      })

      # Build parameters with configurable JSON response format
      params = {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        messages: [
          { role: "system", content: instructions },
          { role: "user", content: developer_message_for_generic }
        ]
      }

      # Add response format based on json_mode setting
      case mode
      when JSON_MODE_STRICT
        params[:response_format] = {
          type: "json_schema",
          json_schema: {
            name: "auto_detect_personal_finance_merchants",
            strict: true,
            schema: json_schema
          }
        }
      when JSON_MODE_OBJECT
        params[:response_format] = { type: "json_object" }
        # JSON_MODE_NONE: no response_format constraint
      end

      response = client.chat(parameters: params)

      Rails.logger.info("Tokens used to auto-detect merchants: #{response.dig("usage", "total_tokens")} (json_mode: #{mode})")

      merchants = extract_merchants_generic(response)
      result = build_response(merchants)

      record_usage(
        model.presence || Provider::Openai::DEFAULT_MODEL,
        response.dig("usage"),
        operation: "auto_detect_merchants",
        metadata: {
          transaction_count: transactions.size,
          merchant_count: user_merchants.size,
          json_mode: mode
        }
      )

      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    AutoDetectedMerchant = Provider::LlmConcept::AutoDetectedMerchant

    def build_response(merchants)
      merchants.map do |merchant|
        AutoDetectedMerchant.new(
          transaction_id: merchant.dig("transaction_id"),
          business_name: normalize_merchant_value(merchant.dig("business_name")),
          business_url: normalize_merchant_value(merchant.dig("business_url")),
        )
      end
    end

    def normalize_merchant_value(value)
      return nil if value.nil? || value == "null" || value.to_s.downcase == "null"

      # Try to match against user merchants for name normalization
      if user_merchants.present?
        # Try exact match first
        exact_match = user_merchants.find { |m| m[:name] == value }
        return exact_match[:name] if exact_match

        # Try case-insensitive match
        case_match = user_merchants.find { |m| m[:name].to_s.downcase == value.to_s.downcase }
        return case_match[:name] if case_match
      end

      value
    end

    def extract_merchants_native(response)
      # Find the message output (not reasoning output)
      message_output = response["output"]&.find { |o| o["type"] == "message" }
      raw = message_output&.dig("content", 0, "text")

      raise Provider::Openai::Error, "No message content found in response" if raw.nil?

      JSON.parse(raw).dig("merchants")
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Invalid JSON in native merchant detection: #{e.message}"
    end

    def extract_merchants_generic(response)
      raw = response.dig("choices", 0, "message", "content")
      parsed = parse_json_flexibly(raw)

      # Handle different response formats from various LLMs
      merchants = parsed.dig("merchants") ||
                  parsed.dig("results") ||
                  (parsed.is_a?(Array) ? parsed : nil)

      raise Provider::Openai::Error, "Could not find merchants in response" if merchants.nil?

      # Normalize field names (some LLMs use different naming)
      merchants.map do |m|
        {
          "transaction_id" => m["transaction_id"] || m["id"] || m["txn_id"],
          "business_name" => m["business_name"] || m["name"] || m["merchant_name"] || m["merchant"],
          "business_url" => m["business_url"] || m["url"] || m["website"]
        }
      end
    end

    # Flexible JSON parsing that handles common LLM output issues
    def parse_json_flexibly(raw)
      return {} if raw.blank?

      # Strip thinking model tags if present (e.g., <think>...</think>)
      cleaned = strip_thinking_tags(raw)

      # Try direct parse first
      JSON.parse(cleaned)
    rescue JSON::ParserError
      # Try multiple extraction strategies in order of preference

      # Strategy 1: Closed markdown code blocks (```json...```)
      if cleaned =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m
        matches = cleaned.scan(/```(?:json)?\s*(\{[\s\S]*?\})\s*```/m).flatten
        matches.reverse_each do |match|
          begin
            return JSON.parse(match)
          rescue JSON::ParserError
            next
          end
        end
      end

      # Strategy 2: Unclosed markdown code blocks (thinking models often forget to close)
      if cleaned =~ /```(?:json)?\s*(\{[\s\S]*\})\s*$/m
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
          # Continue to next strategy
        end
      end

      # Strategy 3: Find JSON object with "merchants" key
      if cleaned =~ /(\{"merchants"\s*:\s*\[[\s\S]*\]\s*\})/m
        matches = cleaned.scan(/(\{"merchants"\s*:\s*\[[\s\S]*?\]\s*\})/m).flatten
        matches.reverse_each do |match|
          begin
            return JSON.parse(match)
          rescue JSON::ParserError
            next
          end
        end
        # Try greedy match if non-greedy failed
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
          # Continue to next strategy
        end
      end

      # Strategy 4: Find any JSON object (last resort)
      if cleaned =~ /(\{[\s\S]*\})/m
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
          # Fall through to error
        end
      end

      raise Provider::Openai::Error, "Could not parse JSON from response: #{raw.truncate(200)}"
    end

    # Strip thinking model tags (<think>...</think>) from response
    def strip_thinking_tags(raw)
      if raw.include?("<think>")
        if raw =~ /<\/think>\s*([\s\S]*)/m
          after_thinking = $1.strip
          return after_thinking if after_thinking.present?
        end
        if raw =~ /<think>([\s\S]*)/m
          return $1
        end
      end
      raw
    end

    def json_schema
      {
        type: "object",
        properties: {
          merchants: {
            type: "array",
            description: "An array of auto-detected merchant businesses for each transaction",
            items: {
              type: "object",
              properties: {
                transaction_id: {
                  type: "string",
                  description: "The internal ID of the original transaction",
                  enum: transactions.map { |t| t[:id] }
                },
                business_name: {
                  type: [ "string", "null" ],
                  description: "The detected business name of the transaction, or `null` if uncertain"
                },
                business_url: {
                  type: [ "string", "null" ],
                  description: "The URL of the detected business, or `null` if uncertain"
                }
              },
              required: [ "transaction_id", "business_name", "business_url" ],
              additionalProperties: false
            }
          }
        },
        required: [ "merchants" ],
        additionalProperties: false
      }
    end

    def developer_message
      <<~MESSAGE.strip_heredoc
        Here are the user's available merchants in JSON format:

        ```json
        #{user_merchants.to_json}
        ```

        Use BOTH your knowledge AND the user-generated merchants to auto-detect the following transactions:

        ```json
        #{transactions.to_json}
        ```

        Return "null" if you are not 80%+ confident in your answer.
      MESSAGE
    end

    # Enhanced developer message with few-shot examples for smaller/local LLMs
    def developer_message_for_generic
      merchant_names = user_merchants.present? ? user_merchants.map { |m| m[:name] }.join(", ") : "(none provided)"

      <<~MESSAGE.strip_heredoc
        USER'S KNOWN MERCHANTS: #{merchant_names}

        TRANSACTIONS TO ANALYZE:
        #{format_transactions_simply}

        EXAMPLES of correct merchant detection:
        - "AMAZON.COM*1A2B3C" → business_name: "Amazon", business_url: "amazon.com"
        - "STARBUCKS STORE #9876" → business_name: "Starbucks", business_url: "starbucks.com"
        - "NETFLIX.COM" → business_name: "Netflix", business_url: "netflix.com"
        - "UBER *TRIP" → business_name: "Uber", business_url: "uber.com"
        - "ACH WITHDRAWAL" → business_name: "null", business_url: "null" (generic)
        - "LOCAL DINER" → business_name: "null", business_url: "null" (generic/unknown)
        - "POS DEBIT 12345" → business_name: "null", business_url: "null" (generic)

        IMPORTANT:
        - Return "null" (as a string) for BOTH name and URL if you cannot confidently identify the business
        - Don't include "www." in URLs
        - Generic descriptions like "Paycheck", "Transfer", "ATM" should return "null"

        Respond with ONLY this JSON format (no other text):
        {"merchants": [{"transaction_id": "...", "business_name": "...", "business_url": "..."}]}
      MESSAGE
    end

    # Format transactions in a simpler, more readable way for smaller LLMs
    def format_transactions_simply
      transactions.map do |t|
        "- ID: #{t[:id]}, Description: \"#{t[:name] || t[:description]}\""
      end.join("\n")
    end
end
