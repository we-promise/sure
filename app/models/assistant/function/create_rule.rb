# frozen_string_literal: true

# CreateRule — saves a new transaction rule, always inactive. Nothing changes
# until apply_rule activates it against a preview's match count, so a rule
# cannot start rewriting transactions (or re-running on every sync) from a
# single call.
class Assistant::Function::CreateRule < Assistant::Function
  include Assistant::Function::RuleSupport

  class << self
    def name
      "create_rule"
    end

    def description
      <<~INSTRUCTIONS
        Saves a new transaction rule. The rule is always saved inactive: it does
        not change any transaction until apply_rule activates it.

        Build the definition from get_rule_options, and check it with
        preview_rule first. Returns the saved rule and the same preview as
        preview_rule; pass its preview_token to apply_rule after checking the sample.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[conditions actions],
      properties: {
        name: {
          type: "string",
          description: "Optional rule name shown in Settings > Rules."
        },
        **definition_properties,
        sample_size: {
          type: "integer",
          description: "Matches to list in the preview (default #{DEFAULT_SAMPLE_SIZE}, max #{MAX_SAMPLE_SIZE})."
        }
      }
    )
  end

  def call(params = {})
    return error("invalid_arguments", "conditions and actions are required.") unless params.key?("conditions") && params.key?("actions")

    rule = family.rules.build(resource_type: "transaction", active: false, name: params["name"].to_s.strip.presence)
    problems = assign_definition(rule, params.slice("conditions", "actions", "effective_date"))
    problems = validate_rule(rule) if problems.empty?
    return error("invalid_rule", "The rule was not saved.", problems: problems) if problems.any?

    rule.save!

    {
      success: true,
      rule: serialize_rule(rule),
      preview: preview(rule, sample_size: resolved_sample_size(params)),
      message: "Rule saved inactive. Check the preview, then call apply_rule with its preview_token to activate it."
    }
  end
end
