class Provider::Anthropic::AutoMerchantDetector
  include Provider::Anthropic::Concerns::UsageRecorder

  TOOL_NAME = "report_merchants".freeze

  attr_reader :client, :model, :transactions, :user_merchants, :langfuse_trace, :family

  def initialize(client, model:, transactions: [], user_merchants: [], langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @transactions = transactions
    @user_merchants = user_merchants
    @langfuse_trace = langfuse_trace
    @family = family
  end

  def auto_detect_merchants
    span = langfuse_trace&.span(name: "auto_detect_merchants_api_call", input: {
      model: model,
      transactions: transactions,
      user_merchants: user_merchants
    })

    response = client.messages.create(
      model: model,
      max_tokens: max_tokens,
      system_: instructions,
      messages: [ { role: "user", content: user_message } ],
      tools: [ output_tool ],
      tool_choice: { type: "tool", name: TOOL_NAME, disable_parallel_tool_use: true }
    )

    merchants_data = extract_merchants(response)
    result = build_response(merchants_data)

    record_usage(model, response.usage, operation: "auto_detect_merchants", metadata: {
      transaction_count: transactions.size,
      merchant_count: user_merchants.size
    })

    span&.end(output: result.map(&:to_h), usage: usage_hash(response.usage))
    result
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    record_usage_error(model, operation: "auto_detect_merchants", error: e, metadata: {
      transaction_count: transactions.size,
      merchant_count: user_merchants.size
    })
    raise
  end

  private
    AutoDetectedMerchant = Provider::LlmConcept::AutoDetectedMerchant

    def max_tokens
      ENV.fetch("ANTHROPIC_MAX_TOKENS", 4096).to_i
    end

    def output_tool
      {
        name: TOOL_NAME,
        description: "Return the detected business name and website URL for each input transaction.",
        input_schema: {
          type: "object",
          properties: {
            merchants: {
              type: "array",
              description: "One detection result per input transaction.",
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
                    description: "Detected business name, or null if uncertain or generic"
                  },
                  business_url: {
                    type: [ "string", "null" ],
                    description: "Business website without the www. subdomain (e.g., \"amazon.com\"), or null if uncertain"
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
      }
    end

    def instructions
      <<~INSTRUCTIONS.strip_heredoc
        You are an assistant to a consumer personal finance app. Detect the business name and website URL
        for each transaction and return the result via the report_merchants tool.

        Follow ALL the rules below:

        - One result per transaction, correlated by transaction_id
        - Do NOT include the www. subdomain in business_url ("amazon.com", not "www.amazon.com")
        - User-provided merchants should only be used when the match is unambiguous
        - Favor null over false positives; only return values when 80%+ confident
        - NEVER return a name/URL for generic descriptions ("Paycheck", "Local diner", "ATM", "POS DEBIT")

        Decision order:
          1. Identify from your knowledge of global businesses
          2. Otherwise, match against the user-provided merchants
          3. Otherwise, return null for both fields
      INSTRUCTIONS
    end

    def user_message
      <<~MESSAGE.strip_heredoc
        User's known merchants:

        ```json
        #{user_merchants.to_json}
        ```

        Transactions to analyze:

        ```json
        #{transactions.to_json}
        ```
      MESSAGE
    end

    def extract_merchants(response)
      tool_use = Array(response.content).find { |block| block_type(block) == :tool_use }
      raise Provider::Anthropic::Error, "Model did not invoke #{TOOL_NAME}" unless tool_use

      input = block_input(tool_use)
      input = JSON.parse(input) if input.is_a?(String)
      merchants = input.is_a?(Hash) ? (input["merchants"] || input[:merchants]) : nil

      raise Provider::Anthropic::Error, "Tool call missing merchants" unless merchants.is_a?(Array)
      merchants
    end

    def build_response(merchants)
      merchants.map do |m|
        AutoDetectedMerchant.new(
          transaction_id: m["transaction_id"] || m[:transaction_id],
          business_name: normalize_merchant_name(m["business_name"] || m[:business_name]),
          business_url: normalize_value(m["business_url"] || m[:business_url])
        )
      end
    end

    def normalize_value(value)
      return nil if value.nil?
      str = value.to_s.strip
      return nil if str.empty? || str.casecmp("null").zero?
      str
    end

    def normalize_merchant_name(value)
      str = normalize_value(value)
      return nil unless str
      return str if user_merchants.blank?

      match = user_merchants.find { |m| m[:name].to_s.casecmp(str).zero? }
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
