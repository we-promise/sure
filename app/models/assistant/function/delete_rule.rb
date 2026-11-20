# frozen_string_literal: true

# DeleteRule — deletes an inactive rule, like the delete button in Settings >
# Rules. An active rule is refused, so deleting one takes a separate
# update_rule active: false first.
class Assistant::Function::DeleteRule < Assistant::Function
  include Assistant::Function::RuleSupport

  class << self
    def name
      "delete_rule"
    end

    def description
      <<~INSTRUCTIONS
        Deletes an inactive transaction rule from get_rules. This cannot be
        undone: its conditions, actions and run history are deleted with it.
        Changes the rule already made to transactions are kept.

        An active rule is not deleted; deactivate it first with update_rule
        active: false.

        Confirm with the user before calling this tool.
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
        }
      }
    )
  end

  def call(params = {})
    rule = find_rule(params["rule_id"])
    return error("not_found", "No rule with id '#{params["rule_id"]}'.") unless rule

    snapshot = nil
    # apply_rule activates the rule under this lock, and lock! reloads it, so
    # an activation since the lookup is seen here.
    rule.with_lock do
      unless rule.active
        snapshot = serialize_rule(rule)
        rule.destroy!
      end
    end

    return error("rule_active", "Deactivate the rule first with update_rule active: false, then delete it.") unless snapshot

    name = snapshot[:name].present? ? "Rule '#{snapshot[:name]}'" : "Rule"
    {
      success: true,
      deleted: true,
      rule: snapshot,
      message: "#{name} deleted. Its run history was deleted with it."
    }
  end
end
