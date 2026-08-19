class Provider::Anthropic::BillSetupSuggester
  include Provider::Anthropic::Concerns::UsageRecorder

  TOOL_NAME = "report_bill_setup".freeze

  attr_reader :client, :model, :charges, :categories, :current_config, :langfuse_trace, :family

  def initialize(client, model:, charges: [], categories: [], current_config: nil, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @charges = charges
    @categories = categories
    @current_config = current_config
    @langfuse_trace = langfuse_trace
    @family = family
  end

  def suggest
    span = langfuse_trace&.span(name: "suggest_bill_setup_api_call", input: {
      model: model,
      charges: charges,
      configure_mode: current_config.present?
    })

    response = client.messages.create(
      model: model,
      max_tokens: max_tokens,
      system_: instructions,
      messages: [ { role: "user", content: user_message } ],
      tools: [ output_tool ],
      tool_choice: { type: "tool", name: TOOL_NAME, disable_parallel_tool_use: true }
    )

    result = build_suggestion(extract_input(response))

    record_usage(model, response.usage, operation: "suggest_bill_setup", metadata: {
      charge_count: charges.size,
      configure_mode: current_config.present?
    })

    span&.end(output: result.to_h, usage: usage_hash(response.usage))
    result
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    record_usage_error(model, operation: "suggest_bill_setup", error: e, metadata: {
      charge_count: charges.size
    })
    raise
  end

  private
    Suggestion = Provider::LlmConcept::BillSetupSuggestion

    def max_tokens
      ENV.fetch("ANTHROPIC_MAX_TOKENS", 4096).to_i
    end

    def output_tool
      nullable_string = { type: [ "string", "null" ] }
      nullable_integer = { type: [ "integer", "null" ] }

      {
        name: TOOL_NAME,
        description: "Report the proposed recurring-bill configuration.",
        input_schema: {
          type: "object",
          properties: {
            name: nullable_string,
            amount: { type: [ "number", "null" ], description: "Typical recent charge, positive." },
            frequency: {
              type: [ "string", "null" ],
              enum: RecurringTransaction::FrequencyPreset::PRESETS + [ nil ]
            },
            day_of_month: nullable_integer,
            weekday: nullable_integer.merge(description: "0 = Sunday; weekly cadences only."),
            month_of_year: nullable_integer,
            category_name: {
              type: [ "string", "null" ],
              description: "Exact match from the provided categories, or null.",
              enum: categories + [ nil ]
            },
            bill_type: { type: [ "string", "null" ], enum: %w[bill subscription installment] + [ nil ] },
            autopay: { type: [ "boolean", "null" ] },
            confidence: { type: [ "number", "null" ] },
            rationale: nullable_string
          },
          required: %w[name amount frequency day_of_month weekday month_of_year category_name bill_type autopay confidence rationale],
          additionalProperties: false
        }
      }
    end

    def instructions
      base = <<~INSTRUCTIONS.strip_heredoc
        You configure recurring-bill records for a personal finance app. Given the dated
        charge history for one obligation, propose the bill's configuration via the
        #{TOOL_NAME} tool.

        Rules:
        - Infer the cadence from the gaps between the dates, never from the row count.
        - amount is the typical recent charge as a positive number; when amounts drift,
          prefer the most recent ones.
        - day_of_month is the modal charge day (monthly-style cadences only); weekday
          only for weekly/biweekly; month_of_year only for annual.
        - bill_type: "subscription" for digital services and memberships, "installment"
          for finite payment plans, otherwise "bill".
        - autopay true only when the history shows automatic-payment markers.
        - Set any field the history cannot support to null. Never guess.
        - confidence is 0 to 1 for the proposal overall; rationale is one short sentence.
      INSTRUCTIONS

      return base if current_config.blank?

      base + <<~CONFIGURE.strip_heredoc

        A current configuration is provided. Propose ONLY fields where the charge history
        contradicts it; set every field that is already right to null.
      CONFIGURE
    end

    def user_message
      message = +"CHARGE HISTORY (date amount description):\n"
      message << charges.map { |charge| "- #{charge[:date]} #{charge[:amount]} #{charge[:name]}" }.join("\n")
      message << "\n\nAVAILABLE CATEGORIES: #{categories.join(", ")}"
      message << "\n\nCURRENT CONFIGURATION:\n#{current_config.to_json}" if current_config.present?
      message
    end

    def extract_input(response)
      tool_use = Array(response.content).find { |block| block_type(block) == :tool_use }
      raise Provider::Anthropic::Error, "Model did not invoke #{TOOL_NAME}" unless tool_use

      input = block_input(tool_use)
      input = JSON.parse(input) if input.is_a?(String)
      input.is_a?(Hash) ? input.stringify_keys : {}
    end

    def build_suggestion(parsed)
      Suggestion.new(
        name: presence_string(parsed["name"]),
        amount: parsed["amount"].is_a?(Numeric) ? parsed["amount"].to_f : nil,
        frequency: presence_string(parsed["frequency"]),
        day_of_month: parsed["day_of_month"].is_a?(Integer) ? parsed["day_of_month"] : nil,
        weekday: parsed["weekday"].is_a?(Integer) ? parsed["weekday"] : nil,
        month_of_year: parsed["month_of_year"].is_a?(Integer) ? parsed["month_of_year"] : nil,
        category_name: presence_string(parsed["category_name"]),
        bill_type: presence_string(parsed["bill_type"]),
        autopay: [ true, false ].include?(parsed["autopay"]) ? parsed["autopay"] : nil,
        confidence: parsed["confidence"].is_a?(Numeric) ? parsed["confidence"].to_f : nil,
        rationale: presence_string(parsed["rationale"])
      )
    end

    def presence_string(value)
      normalized = value.to_s.strip
      return nil if normalized.empty? || normalized.casecmp("null").zero?

      normalized
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
