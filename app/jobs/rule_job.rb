class RuleJob < ApplicationJob
  queue_as :medium_priority

  def perform(rule_or_id, ignore_attribute_locks: false)
    rule = rule_or_id.is_a?(Rule) ? rule_or_id : Rule.find_by(id: rule_or_id)
    return unless rule

    rule.apply(ignore_attribute_locks: ignore_attribute_locks)
  end
end
