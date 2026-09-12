class Provider::Openai::BillSetupSuggester
  include Provider::Openai::Concerns::UsageRecorder

  attr_reader :client, :model, :charges, :categories, :current_config, :langfuse_trace, :family

  def initialize(client, model: "", charges: [], categories: [], current_config: nil, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @charges = charges
    @categories = categories
    @current_config = current_config
    @langfuse_trace = langfuse_trace
    @family = family
  end

  # One chat-completions call with a json_object response format, falling back
  # to no constraint for providers that reject it (the AutoCategorizer's
  # lesson: strict formats break some OpenAI-compatible hosts and local LLMs).
  def suggest
    suggest_with_format({ type: "json_object" })
  rescue Faraday::BadRequestError => e
    Rails.logger.warn("json_object mode failed for bill setup suggestion, retrying without: #{e.message}")
    suggest_with_format(nil)
  end

  private
    Suggestion = Provider::LlmConcept::BillSetupSuggestion

    def suggest_with_format(response_format)
      span = langfuse_trace&.span(name: "suggest_bill_setup_api_call", input: {
        model: model,
        charges: charges,
        configure_mode: current_config.present?
      })

      params = {
        model: model,
        messages: [
          { role: "system", content: instructions },
          { role: "user", content: user_message }
        ]
      }
      params[:response_format] = response_format if response_format

      response = client.chat(parameters: params)

      result = build_suggestion(parse_json_flexibly(response.dig("choices", 0, "message", "content")))

      record_usage(model, response.dig("usage"), operation: "suggest_bill_setup", metadata: {
        charge_count: charges.size,
        configure_mode: current_config.present?
      })

      span&.end(output: result.to_h, usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def instructions
      base = <<~INSTRUCTIONS.strip_heredoc
        You configure recurring-bill records for a personal finance app. Given the dated
        charge history for one obligation, propose the bill's configuration as JSON only.

        Rules:
        - Infer the cadence from the gaps between the dates, never from the row count.
          frequency is one of: monthly, weekly, biweekly, semimonthly, quarterly, semiannual, annual.
        - amount is the typical recent charge as a positive number; when amounts drift,
          prefer the most recent ones.
        - day_of_month is the modal charge day (monthly-style cadences only); weekday
          (0=Sunday) only for weekly/biweekly; month_of_year only for annual.
        - category_name must EXACTLY match one of the provided categories, or null.
        - bill_type: "subscription" for digital services and memberships, "installment"
          for finite payment plans, otherwise "bill".
        - autopay true only when the history shows automatic-payment markers (ACH, AUTOPAY).
        - Set any field the history cannot support to null. Never guess.
        - confidence is 0 to 1 for the proposal overall; rationale is one short sentence.

        Output JSON only, exactly this shape (no markdown, no explanation):
        {"name": ..., "amount": ..., "frequency": ..., "day_of_month": ..., "weekday": ...,
         "month_of_year": ..., "category_name": ..., "bill_type": ..., "autopay": ...,
         "confidence": ..., "rationale": ...}
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

    def build_suggestion(parsed)
      Suggestion.new(
        name: string_or_nil(parsed["name"]),
        amount: numeric_or_nil(parsed["amount"]),
        frequency: string_or_nil(parsed["frequency"]),
        day_of_month: integer_or_nil(parsed["day_of_month"]),
        weekday: integer_or_nil(parsed["weekday"]),
        month_of_year: integer_or_nil(parsed["month_of_year"]),
        category_name: string_or_nil(parsed["category_name"]),
        bill_type: string_or_nil(parsed["bill_type"]),
        autopay: [ true, false ].include?(parsed["autopay"]) ? parsed["autopay"] : nil,
        confidence: numeric_or_nil(parsed["confidence"]),
        rationale: string_or_nil(parsed["rationale"])
      )
    end

    def string_or_nil(value)
      normalized = value.to_s.strip
      return nil if normalized.empty? || normalized.casecmp("null").zero?

      normalized
    end

    def numeric_or_nil(value)
      Float(value)
    rescue TypeError, ArgumentError
      nil
    end

    def integer_or_nil(value)
      Integer(value)
    rescue TypeError, ArgumentError
      nil
    end

    # Same flexible parsing the sibling one-shot classes carry: LLM output may
    # wrap JSON in markdown fences or thinking tags.
    def parse_json_flexibly(raw)
      raise Provider::Openai::Error, "No message content in response" if raw.blank?

      cleaned = strip_thinking_tags(raw)

      begin
        JSON.parse(cleaned)
      rescue JSON::ParserError
        if cleaned =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m
          JSON.parse(Regexp.last_match(1))
        elsif cleaned =~ /(\{[\s\S]*\})/m
          JSON.parse(Regexp.last_match(1))
        else
          raise Provider::Openai::Error, "Could not parse JSON from response: #{raw.truncate(200)}"
        end
      end
    end

    def strip_thinking_tags(raw)
      return raw unless raw.include?("<think>")

      if raw =~ /<\/think>\s*([\s\S]*)/m && Regexp.last_match(1).strip.present?
        Regexp.last_match(1)
      elsif raw =~ /<think>([\s\S]*)/m
        Regexp.last_match(1)
      else
        raw
      end
    end
end
