# Writes the user-facing prose for a GeneratedInsight. The LLM acts as a
# writer, not a reasoner: it receives pre-computed facts and may only phrase
# them, in the language of the locale the job is running under (the family's).
# When no LLM provider is configured (common on self-hosted installs), nobody
# in the family has opted into AI, or the call fails, `write` returns nil and
# no body is stored — Insight#display_body renders the i18n template live
# instead, so insight generation never depends on an external service.
class Insight::BodyWriter
  SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
    You write short insights for a personal finance app.
    Rules:
    - Write 1-2 plain sentences addressed to the user as "you".
    - Write in %{language}.
    - Use only the facts provided. Never invent numbers, dates, or projections.
    - Repeat monetary amounts exactly as formatted in the facts.
    - No financial advice, no jargon, no emoji, no exclamation marks, no lists or headers.
    - Respond with the sentences only.
  PROMPT

  def initialize(family)
    @family = family
  end

  # LLM prose or nil — never a template body; those render live at display
  # time so they follow locale and translation changes.
  def write(generated_insight)
    return nil unless provider

    prompt = <<~PROMPT
      Insight type: #{generated_insight.insight_type.humanize}
      Facts: #{Insight.localize_facts(generated_insight.facts).to_json}
    PROMPT

    response = provider.chat_response(
      prompt,
      model: provider.class.effective_model,
      instructions: format(SYSTEM_PROMPT_TEMPLATE, language: language_name),
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

  private
    attr_reader :family

    # English name of the language the prose must be written in, from the
    # locale the job wrapped around generation (the family's).
    def language_name
      LanguagesHelper::LANGUAGE_MAPPING[I18n.locale] || I18n.locale.to_s
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
