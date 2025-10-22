class Provider::Openai::AutoCategorizer
  def initialize(client, model: "", transactions: [], user_categories: [], custom_provider: false, langfuse_trace: nil)
    @client = client
    @model = model
    @transactions = transactions
    @user_categories = user_categories
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
  end

  def auto_categorize
    if custom_provider
      auto_categorize_openai_generic
    else
      auto_categorize_openai_native
    end
  end

  def instructions
    <<~INSTRUCTIONS.strip_heredoc
      You are an assistant to a consumer personal finance app.  You will be provided a list
      of the user's transactions and a list of the user's categories.  Your job is to auto-categorize
      each transaction.

      Closely follow ALL the rules below while auto-categorizing:

      - Return 1 result per transaction
      - Correlate each transaction by ID (transaction_id)
      - Attempt to match the most specific category possible (i.e. subcategory over parent category)
      - Category and transaction classifications should match (i.e. if transaction is an "expense", the category must have classification of "expense")
      - If you don't know the category, return "null"
        - You should always favor "null" over false positives
        - Be slightly pessimistic.  Only match a category if you're 60%+ confident it is the correct one.
      - Each transaction has varying metadata that can be used to determine the category
        - Note: "hint" comes from 3rd party aggregators and typically represents a category name that
          may or may not match any of the user-supplied categories
    INSTRUCTIONS
  end

  private

    def auto_categorize_openai_native
      span = langfuse_trace&.span(name: "auto_categorize_api_call", input: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        transactions: transactions,
        user_categories: user_categories
      })

      response = client.responses.create(parameters: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        input: [ { role: "developer", content: developer_message } ],
        text: {
          format: {
            type: "json_schema",
            name: "auto_categorize_personal_finance_transactions",
            strict: true,
            schema: json_schema
          }
        },
        instructions: instructions
      })
      Rails.logger.info("Tokens used to auto-categorize transactions: #{response.dig("usage", "total_tokens")}")

      categorizations = extract_categorizations_native(response)
      result = build_response(categorizations)

      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def auto_categorize_openai_generic
      span = langfuse_trace&.span(name: "auto_categorize_api_call", input: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        transactions: transactions,
        user_categories: user_categories
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
            name: "auto_categorize_personal_finance_transactions",
            strict: true,
            schema: json_schema
          }
        }
      })

      Rails.logger.info("Tokens used to auto-categorize transactions: #{response.dig("usage", "total_tokens")}")

      categorizations = extract_categorizations_generic(response)
      result = build_response(categorizations)

      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    attr_reader :client, :model, :transactions, :user_categories, :custom_provider, :langfuse_trace

    AutoCategorization = Provider::LlmConcept::AutoCategorization

    def build_response(categorizations)
      categorizations.map do |categorization|
        AutoCategorization.new(
          transaction_id: categorization.dig("transaction_id"),
          category_name: normalize_category_name(categorization.dig("category_name")),
        )
      end
    end

    def normalize_category_name(category_name)
      return nil if category_name == "null"

      category_name
    end

    def extract_categorizations_native(response)
      # Find the message output (not reasoning output)
      message_output = response["output"]&.find { |o| o["type"] == "message" }
      raw = message_output&.dig("content", 0, "text")

      raise Provider::Openai::Error, "No message content found in response" if raw.nil?

      JSON.parse(raw).dig("categorizations")
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Invalid JSON in native categorization: #{e.message}"
    end

    def extract_categorizations_generic(response)
      raw = response.dig("choices", 0, "message", "content")
      JSON.parse(raw).dig("categorizations")
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Invalid JSON in generic categorization: #{e.message}"
    end

    def json_schema
      {
        type: "object",
        properties: {
          categorizations: {
            type: "array",
            description: "An array of auto-categorizations for each transaction",
            items: {
              type: "object",
              properties: {
                transaction_id: {
                  type: "string",
                  description: "The internal ID of the original transaction",
                  enum: transactions.map { |t| t[:id] }
                },
                category_name: {
                  type: "string",
                  description: "The matched category name of the transaction, or null if no match",
                  enum: [ *user_categories.map { |c| c[:name] }, "null" ]
                }
              },
              required: [ "transaction_id", "category_name" ],
              additionalProperties: false
            }
          }
        },
        required: [ "categorizations" ],
        additionalProperties: false
      }
    end

    def developer_message
      <<~MESSAGE.strip_heredoc
        Here are the user's available categories in JSON format:

        ```json
        #{user_categories.to_json}
        ```

        Use the available categories to auto-categorize the following transactions:

        ```json
        #{transactions.to_json}
        ```
      MESSAGE
    end
end
