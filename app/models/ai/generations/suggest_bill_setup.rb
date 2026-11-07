# Proposes a recurring bill's configuration from its charge history: the add dialog's
# smart-fill (no current configuration) and per-bill smart-configure (only the fields the history
# contradicts come back). Replaces Provider::{Openai,Anthropic}::BillSetupSuggester.
#
# Null is a normal answer here, above all in configure mode, so `auto` JSON mode moves on only
# when the answer doesn't parse (no blank_item check).
class Ai::Generations::SuggestBillSetup < Ai::Generation
  feature :bill_setup
  prompt "bill_setup"
  schema_name "bill_setup_suggestion"

  SCHEMA = {
    type: "object",
    properties: {
      name:          { type: %w[string null] },
      amount:        { type: %w[number null] },
      frequency:     { type: %w[string null], enum: RecurringTransaction::FrequencyPreset::PRESETS + [ nil ] },
      day_of_month:  { type: %w[integer null], minimum: 1, maximum: 31 },
      weekday:       { type: %w[integer null], minimum: 0, maximum: 6 },
      month_of_year: { type: %w[integer null], minimum: 1, maximum: 12 },
      category_name: { type: %w[string null] },
      bill_type:     { type: %w[string null], enum: [ "bill", "subscription", "installment", nil ] },
      autopay:       { type: %w[boolean null] },
      confidence:    { type: %w[number null] },   # clamped into 0..1 by the suggester, as today
      rationale:     { type: %w[string null] }
    },
    required: %w[name amount frequency day_of_month weekday month_of_year category_name bill_type autopay confidence rationale],
    additionalProperties: false
  }.freeze
  schema SCHEMA

  # charges: [{ date:, amount:, name: }]; categories: the family's category names;
  # current_config: the bill's settings in configure mode, nil when filling a new one.
  def initialize(charges:, categories:, family:, user: nil, current_config: nil)
    super(family:, user:)
    @charges, @categories, @current_config = charges, categories, current_config
  end

  def prompt_locals
    { charges: @charges, categories: @categories, current_config: @current_config, configure_mode: @current_config.present? }
  end
end
