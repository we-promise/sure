class Insight::Generator
  GeneratedInsight = Data.define(
    :insight_type, :priority, :title, :body,
    :metadata, :currency, :period_start, :period_end, :dedup_key
  )

  LLM_SYSTEM_PROMPT = <<~PROMPT.freeze
    You are a personal finance assistant writing a single proactive notification for a user.
    You are given a structured summary of a financial signal that has already been computed.
    Your ONLY job is to phrase it in clear, friendly natural language.

    Rules:
    - 1 to 2 sentences, maximum 240 characters.
    - Plain language, no financial jargon, no emoji, no markdown.
    - Do not invent numbers. Only use the figures provided.
    - Do not add advice unless the summary explicitly asks for a suggested action.
    - Write in second person ("you", "your").
  PROMPT

  def initialize(family)
    @family = family
  end

  # Subclasses return Array<GeneratedInsight>
  def generate
    raise NotImplementedError, "#{self.class} must implement #generate"
  end

  private
    attr_reader :family

    def currency
      family.currency
    end

    def format_money(amount)
      Money.new(amount, currency).format
    end

    def convert_to_family_currency(amount, from_currency)
      return amount.to_f if from_currency == family.currency

      Money.new(amount, from_currency).exchange_to(family.currency).amount.to_f
    rescue Money::ConversionError
      amount.to_f
    end

    # Generates the human-readable body via the LLM. Falls back to the provided
    # template string when no LLM provider is configured (e.g. self-hosted
    # without an API key) or the call fails.
    def generate_body(facts:, fallback:)
      provider = llm_provider
      return fallback unless provider

      response = provider.chat_response(
        facts.to_json,
        model: Provider::Openai.effective_model,
        instructions: LLM_SYSTEM_PROMPT,
        family: family
      )

      return fallback unless response.success?

      text = response.data.messages.map(&:output_text).join(" ").strip
      text.presence || fallback
    rescue => e
      Rails.logger.warn("Insight body generation failed for family #{family.id}: #{e.message}")
      fallback
    end

    def llm_provider
      Provider::Registry.get_provider(:openai)
    rescue Provider::Registry::Error
      nil
    end
end
