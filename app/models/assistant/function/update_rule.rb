# frozen_string_literal: true

# UpdateRule — renames a rule, replaces its definition, or deactivates it.
# Changing what an active rule matches or does deactivates it, so the new
# version only runs after apply_rule against a fresh preview.
class Assistant::Function::UpdateRule < Assistant::Function
  include Assistant::Function::RuleSupport

  class << self
    def name
      "update_rule"
    end

    def description
      <<~INSTRUCTIONS
        Updates a transaction rule from get_rules. Any of:
        - name: rename it (an active rule stays active).
        - conditions / actions: replace that whole list (send every item, not
          just the changed one). effective_date: change it, or "" to clear it.
          Any of these deactivates the rule; call apply_rule after checking the
          returned preview.
        - active: false to stop the rule running on sync. It cannot activate a
          rule; use apply_rule for that.

        Rules with AI-backed actions (auto categorize, auto detect merchants)
        must be edited in Settings > Rules.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[rule_id],
      properties: {
        rule_id: {
          type: "string",
          description: "Rule ID from get_rules."
        },
        name: {
          type: "string",
          description: "New name. Pass \"\" to clear it."
        },
        **definition_properties,
        active: {
          type: "boolean",
          description: "Only false is accepted: deactivates the rule."
        },
        sample_size: {
          type: "integer",
          description: "Matches to list in the preview (default #{DEFAULT_SAMPLE_SIZE}, max #{MAX_SAMPLE_SIZE})."
        }
      }
    )
  end

  def call(params = {})
    rule = find_rule(params["rule_id"])
    return error("not_found", "No rule with id '#{params["rule_id"]}'.") unless rule

    active = params.key?("active") ? ActiveModel::Type::Boolean.new.cast(params["active"]) : nil
    return error("cannot_activate", "update_rule cannot activate a rule. Use apply_rule with a preview_token from a preview.") if active == true

    definition = params.slice("conditions", "actions", "effective_date")
    return error("no_changes", "Provide name, conditions, actions, effective_date or active: false.") if definition.empty? && !params.key?("name") && active.nil?

    if rule.actions.any? { |a| BLOCKED_ACTION_TYPES.include?(a.action_type) } && definition.any?
      return error("ai_action", "This rule has an AI-backed action; edit it in Settings > Rules.")
    end

    was_active = rule.active
    rule.name = params["name"].to_s.strip.presence if params.key?("name")
    rule.active = false if active == false || definition.any?

    problems = assign_definition(rule, definition)
    problems = validate_rule(rule) if problems.empty?
    return error("invalid_rule", "The rule was not updated.", problems: problems) if problems.any?

    rule.save!
    rule = find_rule(rule.id)

    message =
      if was_active && !rule.active
        "Rule updated and deactivated. Check the preview, then call apply_rule with its preview_token to activate it again."
      else
        "Rule updated."
      end

    {
      success: true,
      rule: serialize_rule(rule),
      preview: preview(rule, sample_size: resolved_sample_size(params)),
      message: message
    }
  end
end
