class Provider::Openai::AutoMerchantDetector
  include Provider::Openai::Concerns::UsageRecorder

  # JSON response format modes for custom providers
  # - "strict": Use strict JSON schema (requires full OpenAI API compatibility)
  # - "json_object": Use json_object response format (broader compatibility)
  # - "none": No response format constraint (maximum compatibility with local LLMs)
  JSON_MODE_STRICT = "strict"
  JSON_MODE_OBJECT = "json_object"
  JSON_MODE_NONE = "none"

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

  # Determine default JSON mode based on environment and provider type
  def default_json_mode
    # Check environment variable first (allows global override)
    env_mode = ENV["LLM_JSON_MODE"]
    return env_mode if env_mode.present? && [ JSON_MODE_STRICT, JSON_MODE_OBJECT, JSON_MODE_NONE ].include?(env_mode)

    # Custom providers default to no JSON constraints for maximum compatibility
    # Native OpenAI always uses strict mode (handled in auto_detect_merchants_openai_native)
    custom_provider ? JSON_MODE_NONE : JSON_MODE_STRICT
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
      span = langfuse_trace&.span(name: "auto_detect_merchants_api_call", input: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        transactions: transactions,
        user_merchants: user_merchants,
        json_mode: json_mode
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
      case json_mode
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

      Rails.logger.info("Tokens used to auto-detect merchants: #{response.dig("usage", "total_tokens")}")

      merchants = extract_merchants_generic(response)
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

      # Try direct parse first
      JSON.parse(raw)
    rescue JSON::ParserError
      # Try to extract JSON from markdown code blocks
      if raw =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m
        JSON.parse($1)
      # Try to find a JSON object anywhere in the response
      elsif raw =~ /(\{[\s\S]*\})/m
        JSON.parse($1)
      else
        raise Provider::Openai::Error, "Could not parse JSON from response: #{raw.truncate(200)}"
      end
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
