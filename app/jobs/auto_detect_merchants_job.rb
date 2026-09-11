class AutoDetectMerchantsJob < ApplicationJob
  queue_as :medium_priority

  def perform(family, transaction_ids: [], rule_run_id: nil)
    rule_run = RuleRun.find_by(id: rule_run_id) if rule_run_id.present?
    modified_count = family.auto_detect_transaction_merchants(transaction_ids)

    # If this job was part of a rule run, report back the modified count
    rule_run&.complete_job!(modified_count: modified_count)
  rescue => error
    rule_run&.fail_job!(error: error, source: self.class.name, transaction_ids: transaction_ids)

    raise
  end
end
