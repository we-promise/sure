# Writes the user-facing prose for a GeneratedInsight. The LLM acts as a
# writer, not a reasoner: it receives pre-computed facts and may only phrase
# them. When no LLM provider is configured (common on self-hosted installs),
# nobody in the family has opted into AI, or the call fails, the i18n template
# interpolated with the same facts is used instead, so insight generation
# never depends on an external service.
class Insight::BodyWriter
  SYSTEM_PROMPT = <<~PROMPT.freeze
    You write short insights for a personal finance app.
    Rules:
    - Write 1-2 plain sentences addressed to the user as "you".
    - Use only the facts provided. Never invent numbers, dates, or projections.
    - Repeat monetary amounts exactly as formatted in the facts.
    - No financial advice, no jargon, no emoji, no exclamation marks, no lists or headers.
    - Respond with the sentences only.
  PROMPT

  def initialize(family)
    @family = family
  end

  def write(generated_insight)
    llm_body(generated_insight) || template_body(generated_insight)
  end

  private
    attr_reader :family

    def template_body(generated_insight)
      I18n.t(
        "insights.templates.#{generated_insight.template_key}",
        **generated_insight.facts.symbolize_keys
      )
    end

    def llm_body(generated_insight)
      return nil unless provider

      prompt = <<~PROMPT
        Insight type: #{generated_insight.insight_type.humanize}
        Facts: #{generated_insight.facts.to_json}
      PROMPT

      response = provider.chat_response(
        prompt,
        model: provider.class.effective_model,
        instructions: SYSTEM_PROMPT,
        family: family
      )
      return nil unless response.success?

      response.data.messages.filter_map(&:output_text).join(" ").strip.presence
    rescue => e
      DebugLogEntry.capture(
        category: "insights",
        level: "warn",
        message: "Insight::BodyWriter narration failed: #{e.class}: #{e.message}",
        source: "Insight::BodyWriter",
        family: family,
        metadata: { insight_type: generated_insight.insight_type }
      )
      nil
    end

    # This job runs unprompted for every family, so unlike chat (where the user
    # initiates each call) LLM narration is gated on someone in the family
    # having AI enabled — consent to share financial data with the provider,
    # and a cost cap in managed mode. Everyone else gets the template body.
    def provider
      return @provider if defined?(@provider)
      return @provider = nil unless family.users.any?(&:ai_enabled?)

      @provider = Provider::Registry.preferred_llm_provider
    end
end
