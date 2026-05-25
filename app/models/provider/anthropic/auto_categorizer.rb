class Provider::Anthropic::AutoCategorizer
  include Provider::Anthropic::Concerns::UsageRecorder

  TOOL_NAME = "report_categorizations".freeze

  attr_reader :client, :model, :transactions, :user_categories, :langfuse_trace, :family

  def initialize(client, model:, transactions: [], user_categories: [], langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @transactions = transactions
    @user_categories = user_categories
    @langfuse_trace = langfuse_trace
    @family = family
  end

  def auto_categorize
    span = langfuse_trace&.span(name: "auto_categorize_api_call", input: {
      model: model,
      transactions: transactions,
      user_categories: user_categories
    })

    response = client.messages.create(
      model: model,
      max_tokens: max_tokens,
      system_: instructions,
      messages: [ { role: "user", content: user_message } ],
      tools: [ output_tool ],
      tool_choice: { type: "tool", name: TOOL_NAME, disable_parallel_tool_use: true }
    )

    categorizations = extract_categorizations(response)
    result = build_response(categorizations)

    record_usage(model, response.usage, operation: "auto_categorize", metadata: {
      transaction_count: transactions.size,
      category_count: user_categories.size
    })

    span&.end(output: result.map(&:to_h), usage: usage_hash(response.usage))
    result
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    record_usage_error(model, operation: "auto_categorize", error: e, metadata: {
      transaction_count: transactions.size,
      category_count: user_categories.size
    })
    raise
  end

  private
    AutoCategorization = Provider::LlmConcept::AutoCategorization

    def max_tokens
      ENV.fetch("ANTHROPIC_MAX_TOKENS", 4096).to_i
    end

    def output_tool
      {
        name: TOOL_NAME,
        description: "Return the categorization decision for each input transaction.",
        input_schema: {
          type: "object",
          properties: {
            categorizations: {
              type: "array",
              description: "One categorization per input transaction.",
              items: {
                type: "object",
                properties: {
                  transaction_id: {
                    type: "string",
                    description: "The internal ID of the original transaction",
                    enum: transactions.map { |t| t[:id] }
                  },
                  category_name: {
                    type: [ "string", "null" ],
                    description: "Matched category name from the user's categories, or null when uncertain.",
                    enum: [ *user_categories.map { |c| c[:name] }, nil ]
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
      }
    end

    def instructions
      <<~INSTRUCTIONS.strip_heredoc
        You are an assistant to a consumer personal finance app. You will be provided a list of the user's
        transactions and a list of the user's categories. Your job is to auto-categorize each transaction
        and return the result via the report_categorizations tool.

        Follow ALL the rules below:

        - Return one result per transaction, correlated by transaction_id
        - Use the most specific category possible (subcategory over parent category)
        - Any category may be used regardless of whether the transaction is income or expense
        - Return null for category_name when you are not 60%+ confident, or when the description is
          generic/ambiguous (e.g., "POS DEBIT", "ACH WITHDRAWAL", "CHECK #1234")
        - The `hint` field on a transaction (when present) comes from third-party aggregators and may
          or may not match the user's categories — treat it as a weak signal
      INSTRUCTIONS
    end

    def user_message
      <<~MESSAGE.strip_heredoc
        Here are the user's available categories in JSON:

        ```json
        #{user_categories.to_json}
        ```

        Auto-categorize the following transactions:

        ```json
        #{transactions.to_json}
        ```
      MESSAGE
    end

    def extract_categorizations(response)
      tool_use = Array(response.content).find { |block| block_type(block) == :tool_use }
      raise Provider::Anthropic::Error, "Model did not invoke #{TOOL_NAME}" unless tool_use

      input = block_input(tool_use)
      input = JSON.parse(input) if input.is_a?(String)
      categorizations = input.is_a?(Hash) ? (input["categorizations"] || input[:categorizations]) : nil

      raise Provider::Anthropic::Error, "Tool call missing categorizations" unless categorizations.is_a?(Array)
      categorizations
    end

    def build_response(categorizations)
      categorizations.map do |c|
        category_name = c["category_name"] || c[:category_name]
        AutoCategorization.new(
          transaction_id: c["transaction_id"] || c[:transaction_id],
          category_name: normalize_category(category_name)
        )
      end
    end

    def normalize_category(value)
      return nil if value.nil?
      str = value.to_s.strip
      return nil if str.empty? || str.casecmp("null").zero?

      match = user_categories.find { |c| c[:name].to_s.casecmp(str).zero? }
      match ? match[:name] : str
    end

    def block_type(block)
      raw = block.respond_to?(:type) ? block.type : block[:type] || block["type"]
      raw.to_s.to_sym
    end

    def block_input(block)
      block.respond_to?(:input) ? block.input : (block[:input] || block["input"])
    end

    def usage_hash(raw_usage)
      return {} unless raw_usage
      {
        "input_tokens" => raw_usage.input_tokens.to_i,
        "output_tokens" => raw_usage.output_tokens.to_i,
        "total_tokens" => raw_usage.input_tokens.to_i + raw_usage.output_tokens.to_i
      }
    end
end
