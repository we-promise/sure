class AutoCategorizeJob < ApplicationJob
  queue_as :medium_priority

  def perform(family, transaction_ids: [], rule_run_id: nil)
    modified_count = family.auto_categorize_transactions(transaction_ids)

    # If this job was part of a rule run, report back the modified count
    if rule_run_id.present?
      rule_run = RuleRun.find_by(id: rule_run_id)
      rule_run&.complete_job!(modified_count: modified_count)
    end
  end
end
