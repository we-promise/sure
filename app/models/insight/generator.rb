# Base class for all insight generators.
#
# Subclasses must implement #generate, returning an Array<GeneratedInsight>.
# Financial reasoning is done in pure Ruby using existing analytics infrastructure.
# The LLM is invoked only to write the human-readable body text.
class Insight::Generator
  GeneratedInsight = Data.define(
    :insight_type,
    :priority,
    :title,
    :body,
    :metadata,
    :currency,
    :period_start,
    :period_end,
    :dedup_key
  )

  attr_reader :family

  def initialize(family)
    @family = family
  end

  def generate
    raise NotImplementedError, "#{self.class.name} must implement #generate"
  end

  private
    def llm
      @llm ||= Provider::Registry.get_provider(:openai)
    end

    # Generates a 1-2 sentence natural-language explanation using the LLM.
    # Falls back to a bare template string if no LLM is configured.
    def generate_body(prompt)
      return prompt unless llm

      response = llm.chat_response(
        prompt,
        model: Provider::Openai.effective_model,
        instructions: system_instructions
      )

      response.messages.first&.output_text&.strip.presence || prompt
    rescue => e
      Rails.logger.warn("[Insight::Generator] LLM body generation failed: #{e.message}")
      prompt
    end

    def system_instructions
      sym = currency_symbol
      <<~PROMPT
        You are a concise financial insights writer for a personal finance app.
        Write exactly 1-2 sentences in plain, conversational English.
        Be specific with numbers. Use #{sym} for currency amounts.
        Do not use jargon, emoji, or give investment advice.
      PROMPT
    end

    def currency_symbol
      Money::Currency.new(family.currency).symbol
    rescue Money::Currency::UnknownCurrency
      family.currency
    end
end
