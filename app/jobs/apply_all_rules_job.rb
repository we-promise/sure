class ApplyAllRulesJob < ApplicationJob
  queue_as :medium_priority

  def perform(family, execution_type: "manual", transaction_ids: nil)
    family.rules.where(resource_type: "transaction").find_each do |rule|
      options = { ignore_attribute_locks: true, execution_type: execution_type }
      options[:transaction_ids] = transaction_ids if transaction_ids
      RuleJob.perform_now(rule, **options)
    end
  end
end
