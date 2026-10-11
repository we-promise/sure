# frozen_string_literal: true

# PreviewRule — shows what a rule matches without changing anything, for a
# saved rule or an unsaved definition. For a saved rule it also issues the
# preview_token apply_rule requires.
class Assistant::Function::PreviewRule < Assistant::Function
  include Assistant::Function::RuleSupport

  class << self
    def name
      "preview_rule"
    end

    def description
      <<~INSTRUCTIONS
        Shows which transactions a rule matches, without changing anything.
        Pass either rule_id (a saved rule) or an unsaved definition (conditions,
        actions, optional effective_date); see get_rule_options for valid values.

        Returns match_count (every matching transaction in the family, which is
        what the rule would touch), a sample of the most recent matches in
        accounts you can see, with their current category and merchant, and the
        actions in readable form. Check the sample before create_rule or
        apply_rule: a loose condition (e.g. "greater than" instead of "equal to")
        rewrites far more transactions than intended.

        For a saved rule it also returns preview_token, which apply_rule needs.
        No token is issued with sample_size 0, since no matches are shown.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        rule_id: {
          type: "string",
          description: "A saved rule from get_rules. Omit when passing a definition."
        },
        **definition_properties,
        sample_size: {
          type: "integer",
          description: "Matches to list, most recent first (default #{DEFAULT_SAMPLE_SIZE}, max #{MAX_SAMPLE_SIZE})."
        }
      }
    )
  end

  def call(params = {})
    definition_given = params.key?("conditions") || params.key?("actions")

    if params["rule_id"].present?
      return error("invalid_arguments", "Pass either rule_id or a definition, not both.") if definition_given

      rule = find_rule(params["rule_id"])
      return error("not_found", "No rule with id '#{params["rule_id"]}'.") unless rule
    else
      return error("invalid_arguments", "Pass rule_id or a definition with conditions and actions.") unless definition_given

      rule = family.rules.build(resource_type: "transaction", active: false)
      problems = assign_definition(rule, params.slice("conditions", "actions", "effective_date"))
      problems = validate_rule(rule) if problems.empty?
      return error("invalid_rule", "The rule definition is not valid.", problems: problems) if problems.any?
    end

    { success: true, rule: serialize_rule(rule), preview: preview(rule, sample_size: resolved_sample_size(params)) }
  end
end
