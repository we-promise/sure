class Provider::Openai::ProviderMerchantEnhancer
  include Provider::Openai::Concerns::UsageRecorder

  attr_reader :client, :model, :merchants, :custom_provider, :langfuse_trace, :family, :json_mode

  def initialize(client, model: "", merchants:, custom_provider: false, langfuse_trace: nil, family: nil, json_mode: nil)
    @client = client
    @model = model
    @merchants = merchants
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
    @json_mode = json_mode || default_json_mode
  end

  VALID_JSON_MODES = Provider::Openai::AutoMerchantDetector::VALID_JSON_MODES

  def default_json_mode
    env_mode = ENV["LLM_JSON_MODE"]
    return env_mode if env_mode.present? && VALID_JSON_MODES.include?(env_mode)

    setting_mode = Setting.openai_json_mode
    return setting_mode if setting_mode.present? && VALID_JSON_MODES.include?(setting_mode)

    Provider::Openai::AutoMerchantDetector::JSON_MODE_AUTO
  end

  def enhance_merchants
    if custom_provider
      enhance_merchants_generic
    else
      enhance_merchants_native
    end
  end

  def instructions
    if custom_provider
      simple_instructions
    else
      detailed_instructions
    end
  end

  def simple_instructions
    <<~INSTRUCTIONS.strip_heredoc
      Identify business websites from merchant names. Return JSON only.

      Rules:
      1. Match merchant_id exactly from input
      2. Return the business website URL without "www." prefix
      3. Return "null" if uncertain, generic, or a local business
      4. Only return values if 80%+ confident

      Example output format:
      {"merchants": [{"merchant_id": "id_001", "business_url": "amazon.com"}]}
    INSTRUCTIONS
  end

  def detailed_instructions
    <<~INSTRUCTIONS.strip_heredoc
      You are an assistant to a consumer personal finance app.

      Given a list of merchant names, identify the business website URL for each.

      Closely follow ALL the rules below:

      - Return 1 result per merchant
      - Correlate each merchant by ID (merchant_id)
      - Do not include the subdomain in the business_url (i.e. "amazon.com" not "www.amazon.com")
      - Be slightly pessimistic. We favor returning "null" over returning a false positive.
      - NEVER return a URL for generic or local merchant names (e.g. "Local Diner", "Gas Station", "ATM Withdrawal")

      Determining a value:

      - Attempt to determine the website URL from your knowledge of global and regional businesses
      - If no certain match, return "null"

      Example 1 (known business):

      ```
      Merchant name: "Walmart"

      Result:
      - business_url: "walmart.com"
      ```

      Example 2 (generic/local business):

      ```
      Merchant name: "Local diner"

      Result:
      - business_url: null
      ```
    INSTRUCTIONS
  end

  private

    def enhance_merchants_native
      span = langfuse_trace&.span(name: "enhance_provider_merchants_api_call", input: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        merchants: merchants
      })

      response = client.responses.create(parameters: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        input: [ { role: "developer", content: developer_message } ],
        text: {
          format: {
            type: "json_schema",
            name: "enhance_provider_merchants",
            strict: true,
            schema: json_schema
          }
        },
        instructions: instructions
      })

      Rails.logger.info("Tokens used to enhance provider merchants: #{response.dig("usage", "total_tokens")}")

      result = extract_and_build_response_native(response)

      record_usage(
        model.presence || Provider::Openai::DEFAULT_MODEL,
        response.dig("usage"),
        operation: "enhance_provider_merchants",
        metadata: { merchant_count: merchants.size }
      )

      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def enhance_merchants_generic
      if json_mode == Provider::Openai::AutoMerchantDetector::JSON_MODE_AUTO
        enhance_merchants_with_auto_mode
      else
        enhance_merchants_with_mode(json_mode)
      end
    rescue Faraday::BadRequestError => e
      if json_mode == Provider::Openai::AutoMerchantDetector::JSON_MODE_STRICT || json_mode == Provider::Openai::AutoMerchantDetector::JSON_MODE_AUTO
        Rails.logger.warn("Strict JSON mode failed for merchant enhancement, falling back to none mode: #{e.message}")
        enhance_merchants_with_mode(Provider::Openai::AutoMerchantDetector::JSON_MODE_NONE)
      else
        raise
      end
    end

    def enhance_merchants_with_auto_mode
      result = enhance_merchants_with_mode(Provider::Openai::AutoMerchantDetector::JSON_MODE_STRICT)

      null_count = result.count { |r| r.business_url.nil? }
      missing_count = merchants.size - result.size
      failed_count = null_count + missing_count
      failed_ratio = merchants.size > 0 ? failed_count.to_f / merchants.size : 0.0

      if failed_ratio > Provider::Openai::AutoMerchantDetector::AUTO_MODE_NULL_THRESHOLD
        Rails.logger.info("Auto mode: #{(failed_ratio * 100).round}% failed in strict mode for merchant enhancement, retrying with none mode")
        enhance_merchants_with_mode(Provider::Openai::AutoMerchantDetector::JSON_MODE_NONE)
      else
        result
      end
    end

    def enhance_merchants_with_mode(mode)
      span = langfuse_trace&.span(name: "enhance_provider_merchants_api_call", input: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        merchants: merchants,
        json_mode: mode
      })

      params = {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        messages: [
          { role: "system", content: instructions },
          { role: "user", content: developer_message_for_generic }
        ]
      }

      case mode
      when Provider::Openai::AutoMerchantDetector::JSON_MODE_STRICT
        params[:response_format] = {
          type: "json_schema",
          json_schema: {
            name: "enhance_provider_merchants",
            strict: true,
            schema: json_schema
          }
        }
      when Provider::Openai::AutoMerchantDetector::JSON_MODE_OBJECT
        params[:response_format] = { type: "json_object" }
      end

      response = client.chat(parameters: params)

      Rails.logger.info("Tokens used to enhance provider merchants: #{response.dig("usage", "total_tokens")} (json_mode: #{mode})")

      result = extract_and_build_response_generic(response)

      record_usage(
        model.presence || Provider::Openai::DEFAULT_MODEL,
        response.dig("usage"),
        operation: "enhance_provider_merchants",
        metadata: { merchant_count: merchants.size, json_mode: mode }
      )

      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    EnhancedMerchant = Provider::LlmConcept::EnhancedMerchant

    def build_response(raw_merchants)
      raw_merchants.map do |merchant|
        EnhancedMerchant.new(
          merchant_id: merchant.dig("merchant_id"),
          business_url: normalize_value(merchant.dig("business_url"))
        )
      end
    end

    def normalize_value(value)
      return nil if value.nil? || value == "null" || value.to_s.downcase == "null"
      value
    end

    def extract_and_build_response_native(response)
      message_output = response["output"]&.find { |o| o["type"] == "message" }
      raw = message_output&.dig("content", 0, "text")

      raise Provider::Openai::Error, "No message content found in response" if raw.nil?

      merchants_data = JSON.parse(raw).dig("merchants")
      build_response(merchants_data)
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Invalid JSON in merchant enhancement: #{e.message}"
    end

    def extract_and_build_response_generic(response)
      raw = response.dig("choices", 0, "message", "content")
      parsed = parse_json_flexibly(raw)

      merchants_data = parsed.dig("merchants") ||
                       parsed.dig("results") ||
                       (parsed.is_a?(Array) ? parsed : nil)

      raise Provider::Openai::Error, "Could not find merchants in response" if merchants_data.nil?

      merchants_data.map! do |m|
        {
          "merchant_id" => m["merchant_id"] || m["id"],
          "business_url" => m["business_url"] || m["url"] || m["website"]
        }
      end

      build_response(merchants_data)
    end

    # Reuse flexible JSON parsing from AutoMerchantDetector
    def parse_json_flexibly(raw)
      return {} if raw.blank?

      cleaned = strip_thinking_tags(raw)

      JSON.parse(cleaned)
    rescue JSON::ParserError
      # Strategy 1: Closed markdown code blocks
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

      # Strategy 2: Unclosed markdown code blocks
      if cleaned =~ /```(?:json)?\s*(\{[\s\S]*\})\s*$/m
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
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
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
        end
      end

      # Strategy 4: Find any JSON object
      if cleaned =~ /(\{[\s\S]*\})/m
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
        end
      end

      raise Provider::Openai::Error, "Could not parse JSON from response: #{raw.truncate(200)}"
    end

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
            description: "An array of merchant website detections",
            items: {
              type: "object",
              properties: {
                merchant_id: {
                  type: "string",
                  description: "The internal ID of the merchant",
                  enum: merchants.map { |m| m[:id] }
                },
                business_url: {
                  type: [ "string", "null" ],
                  description: "The website URL of the business, or `null` if uncertain"
                }
              },
              required: [ "merchant_id", "business_url" ],
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
        Identify the business website URL for each of the following merchants:

        ```json
        #{merchants.to_json}
        ```

        Return "null" if you are not 80%+ confident in your answer.
      MESSAGE
    end

    def developer_message_for_generic
      <<~MESSAGE.strip_heredoc
        MERCHANTS TO IDENTIFY:
        #{format_merchants_simply}

        EXAMPLES of correct website detection:
        - "Amazon" → business_url: "amazon.com"
        - "Starbucks" → business_url: "starbucks.com"
        - "Netflix" → business_url: "netflix.com"
        - "Local Diner" → business_url: "null" (generic/unknown)
        - "ATM Withdrawal" → business_url: "null" (generic)

        IMPORTANT:
        - Return "null" (as a string) if you cannot confidently identify the business website
        - Don't include "www." in URLs

        Respond with ONLY this JSON format (no other text):
        {"merchants": [{"merchant_id": "...", "business_url": "..."}]}
      MESSAGE
    end

    def format_merchants_simply
      merchants.map do |m|
        "- ID: #{m[:id]}, Name: #{m[:name].to_json}"
      end.join("\n")
    end
end
