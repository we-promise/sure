# frozen_string_literal: true

# ApplyRule — activates a rule and applies it to existing transactions, like
# the Apply button on the rule confirmation page. It requires the match count
# from a preview and refuses when the current count differs, so a stale or
# skipped preview cannot be applied.
class Assistant::Function::ApplyRule < Assistant::Function
  include Assistant::Function::RuleSupport

  class << self
    def name
      "apply_rule"
    end

    def description
      <<~INSTRUCTIONS
        Activates a rule and applies it to the transactions it matches now. Once
        active, it also runs on every future sync. Undo future runs with
        update_rule active: false; changes already made are not reverted.

        expected_count must equal match_count from the latest preview_rule,
        create_rule or update_rule for this rule; if the matches have changed,
        nothing is applied and the new preview is returned.

        By default transactions whose category, merchant, name or tags were set
        by hand keep them. Pass override_locked: true to overwrite those too
        (what the Settings > Rules Apply button does).

        Runs in the background; check the result later with get_rules rule_id.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[rule_id expected_count],
      properties: {
        rule_id: {
          type: "string",
          description: "Rule ID from get_rules or create_rule."
        },
        expected_count: {
          type: "integer",
          description: "match_count from the latest preview of this rule."
        },
        override_locked: {
          type: "boolean",
          description: "Also overwrite values the user set by hand (default false)."
        }
      }
    )
  end

  def call(params = {})
    rule = find_rule(params["rule_id"])
    return error("not_found", "No rule with id '#{params["rule_id"]}'.") unless rule

    if rule.actions.any? { |a| BLOCKED_ACTION_TYPES.include?(a.action_type) }
      return error("ai_action", "This rule has an AI-backed action; apply it in Settings > Rules, which shows the cost estimate.")
    end

    expected = Integer(params["expected_count"].to_s, exception: false)
    return error("invalid_arguments", "expected_count must be the integer match_count from a preview.") if expected.nil?

    override_locked = ActiveModel::Type::Boolean.new.cast(params["override_locked"]) || false

    current = nil
    rule.with_lock do
      current = rule.affected_resource_count
      rule.update!(active: true) if current == expected
    end

    if current != expected
      return error(
        "count_mismatch",
        "The rule now matches #{current} transactions, not #{expected}. Nothing was applied; check this preview and retry.",
        rule: serialize_rule(rule),
        preview: preview(rule)
      )
    end

    rule.apply_later(ignore_attribute_locks: override_locked)

    {
      success: true,
      rule: serialize_rule(rule),
      applied_to: expected,
      override_locked: override_locked,
      message: "Rule activated and queued to apply to #{expected} transactions. It will also run on future syncs."
    }
  end
end
