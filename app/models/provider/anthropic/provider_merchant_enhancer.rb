class Provider::Anthropic::ProviderMerchantEnhancer
  include Provider::Anthropic::Concerns::UsageRecorder

  TOOL_NAME = "report_enhancements".freeze

  attr_reader :client, :model, :merchants, :langfuse_trace, :family

  def initialize(client, model:, merchants: [], langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @merchants = merchants
    @langfuse_trace = langfuse_trace
    @family = family
  end

  def enhance_merchants
    span = langfuse_trace&.span(name: "enhance_provider_merchants_api_call", input: {
      model: model,
      merchants: merchants
    })

    response = client.messages.create(
      model: model,
      max_tokens: max_tokens,
      system_: instructions,
      messages: [ { role: "user", content: user_message } ],
      tools: [ output_tool ],
      tool_choice: { type: "tool", name: TOOL_NAME, disable_parallel_tool_use: true }
    )

    enhanced = extract_enhancements(response)
    result = build_response(enhanced)

    record_usage(model, response.usage, operation: "enhance_provider_merchants", metadata: { merchant_count: merchants.size })

    span&.end(output: result.map(&:to_h), usage: usage_hash(response.usage))
    result
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    record_usage_error(model, operation: "enhance_provider_merchants", error: e, metadata: { merchant_count: merchants.size })
    raise
  end

  private
    EnhancedMerchant = Provider::LlmConcept::EnhancedMerchant

    def max_tokens
      ENV.fetch("ANTHROPIC_MAX_TOKENS", 4096).to_i
    end

    def output_tool
      {
        name: TOOL_NAME,
        description: "Return the business website URL for each input merchant.",
        input_schema: {
          type: "object",
          properties: {
            merchants: {
              type: "array",
              description: "One result per input merchant.",
              items: {
                type: "object",
                properties: {
                  merchant_id: {
                    type: "string",
                    description: "The merchant's internal ID",
                    enum: merchants.map { |m| m[:id].to_s }
                  },
                  business_url: {
                    type: [ "string", "null" ],
                    description: "Business website without the www. subdomain, or null if uncertain or local"
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
      }
    end

    def instructions
      <<~INSTRUCTIONS.strip_heredoc
        You are an assistant to a consumer personal finance app. Given a list of merchant names, identify
        the business website URL for each and return the result via the report_enhancements tool.

        Follow ALL the rules below:

        - One result per merchant, correlated by merchant_id
        - Do NOT include the www. subdomain ("walmart.com", not "www.walmart.com")
        - Favor null over false positives; only return a URL when 80%+ confident
        - NEVER return a URL for generic or local-only merchants ("Local diner", "Gas station", "ATM withdrawal")
      INSTRUCTIONS
    end

    def user_message
      <<~MESSAGE.strip_heredoc
        Enhance the following merchants by identifying each one's website URL:

        ```json
        #{merchants.to_json}
        ```
      MESSAGE
    end

    def extract_enhancements(response)
      tool_use = Array(response.content).find { |block| block_type(block) == :tool_use }
      raise Provider::Anthropic::Error, "Model did not invoke #{TOOL_NAME}" unless tool_use

      input = block_input(tool_use)
      input = JSON.parse(input) if input.is_a?(String)
      enhanced = input.is_a?(Hash) ? (input["merchants"] || input[:merchants]) : nil

      raise Provider::Anthropic::Error, "Tool call missing merchants" unless enhanced.is_a?(Array)
      enhanced
    end

    def build_response(enhanced)
      enhanced.map do |m|
        EnhancedMerchant.new(
          merchant_id: m["merchant_id"] || m[:merchant_id],
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
