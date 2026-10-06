# frozen_string_literal: true

# GetRules — lists the family's transaction rules in readable form: each
# condition and action with ids resolved to names, whether the rule is active,
# and its latest run.
class Assistant::Function::GetRules < Assistant::Function
  include Assistant::Function::RuleSupport

  class << self
    def name
      "get_rules"
    end

    def description
      <<~INSTRUCTIONS
        Lists the family's transaction rules: conditions, actions (with account,
        category, tag and merchant names), whether each rule is active, its
        effective_date, and its latest run.

        Active rules run again on every sync. Pass rule_id for a single rule,
        which also includes how many transactions it currently matches.
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
          description: "Optional. Return only this rule, with its current match count."
        },
        active: {
          type: "boolean",
          description: "Optional. true for active rules only, false for inactive only."
        }
      }
    )
  end

  def call(params = {})
    if params["rule_id"].present?
      rule = find_rule(params["rule_id"])
      return error("not_found", "No rule with id '#{params["rule_id"]}'.") unless rule

      return { success: true, rule: serialize_rule(rule, include_last_run: true).merge(match_count: rule.affected_resource_count) }
    end

    rules = family.rules.includes(:actions, conditions: :sub_conditions).order(:name, :created_at)
    rules = rules.where(active: ActiveModel::Type::Boolean.new.cast(params["active"])) unless params["active"].nil?

    {
      success: true,
      total: rules.size,
      rules: rules.map { |rule| serialize_rule(rule, include_last_run: true) }
    }
  end
end
