# frozen_string_literal: true

# ApplyRule — activates a rule and applies it to existing transactions, like
# the Apply button on the rule confirmation page. It needs the preview_token
# from a preview of the rule as it is now, so a skipped, stale or edited
# preview cannot be applied (see RuleSupport).
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

        preview_token must come from the latest preview_rule, create_rule or
        update_rule for this rule (get_rules does not issue one). It expires
        after #{Assistant::Function::RuleSupport::PREVIEW_TOKEN_TTL.inspect}. If the rule or its matches have
        changed since, nothing is applied and a fresh preview, with a new
        token, is returned.

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
      required: %w[rule_id preview_token],
      properties: {
        rule_id: {
          type: "string",
          description: "Rule ID from get_rules or create_rule."
        },
        preview_token: {
          type: "string",
          description: "preview_token from the latest preview of this rule."
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

    token = read_preview_token(params["preview_token"], rule)
    unless token
      return error(
        "preview_required",
        "Preview this rule first (preview_rule with rule_id) and pass its preview_token. Tokens expire after #{PREVIEW_TOKEN_TTL.inspect}."
      )
    end

    override_locked = ActiveModel::Type::Boolean.new.cast(params["override_locked"]) || false

    current = nil
    unchanged = false
    rule.with_lock do
      current = rule.affected_resource_count
      unchanged = definition_digest(rule) == token["definition"] && current == token["match_count"]
      rule.update!(active: true) if unchanged
    end

    unless unchanged
      return error(
        "preview_stale",
        "The rule or its matches changed since that preview (it now matches #{current} transactions). Nothing was applied; check this preview and retry with its token.",
        rule: serialize_rule(rule),
        preview: preview(rule)
      )
    end

    rule.apply_later(ignore_attribute_locks: override_locked)

    {
      success: true,
      rule: serialize_rule(rule),
      applied_to: current,
      override_locked: override_locked,
      message: "Rule activated and queued to apply to #{current} transactions. It will also run on future syncs."
    }
  end
end
