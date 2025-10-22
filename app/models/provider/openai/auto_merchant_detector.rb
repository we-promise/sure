class Provider::Openai::AutoMerchantDetector
  def initialize(client, model: "", transactions:, user_merchants:, custom_provider: false, langfuse_trace: nil)
    @client = client
    @model = model
    @transactions = transactions
    @user_merchants = user_merchants
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
  end

  def auto_detect_merchants
    if custom_provider
      auto_detect_merchants_openai_generic
    else
      auto_detect_merchants_openai_native
    end
  end

  def instructions
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
        user_merchants: user_merchants
      })

      response = client.chat(parameters: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        messages: [
          { role: "system", content: instructions },
          { role: "user", content: developer_message }
        ],
        response_format: {
          type: "json_schema",
          json_schema: {
            name: "auto_detect_personal_finance_merchants",
            strict: true,
            schema: json_schema
          }
        }
      })

      Rails.logger.info("Tokens used to auto-detect merchants: #{response.dig("usage", "total_tokens")}")

      merchants = extract_merchants_generic(response)
      result = build_response(merchants)

      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    attr_reader :client, :model, :transactions, :user_merchants, :custom_provider, :langfuse_trace

    AutoDetectedMerchant = Provider::LlmConcept::AutoDetectedMerchant

    def build_response(categorizations)
      categorizations.map do |categorization|
        AutoDetectedMerchant.new(
          transaction_id: categorization.dig("transaction_id"),
          business_name: normalize_ai_value(categorization.dig("business_name")),
          business_url: normalize_ai_value(categorization.dig("business_url")),
        )
      end
    end

    def normalize_ai_value(ai_value)
      return nil if ai_value == "null"

      ai_value
    end

    def extract_merchants_native(response)
      raw = response.dig("output", 0, "content", 0, "text")
      JSON.parse(raw).dig("merchants")
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Invalid JSON in native merchant detection: #{e.message}"
    end

    def extract_merchants_generic(response)
      raw = response.dig("choices", 0, "message", "content")
      JSON.parse(raw).dig("merchants")
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Invalid JSON in generic merchant detection: #{e.message}"
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
end
