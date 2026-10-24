class AutoCategorizeJob < ApplicationJob
  queue_as :ai_low_priority

  # recheck_eligibility: the API endpoint filters what it queues, but a
  # transaction can become a transfer leg (transfer matching runs on account
  # sync) or a split parent, or get a category by hand, before this low
  # priority job runs; those are dropped here instead of categorized.
  def perform(family, transaction_ids: [], rule_run_id: nil, recheck_eligibility: false)
    if recheck_eligibility
      transaction_ids = family.auto_categorizable_transactions.where(id: transaction_ids).pluck(:id)
      return if transaction_ids.empty?
    end

    rule_run = RuleRun.find_by(id: rule_run_id) if rule_run_id.present?
    modified_count = family.auto_categorize_transactions(transaction_ids)

    # If this job was part of a rule run, report back the modified count
    rule_run&.complete_job!(modified_count: modified_count)
  rescue => error
    rule_run&.fail_job!(error: error, source: self.class.name, transaction_ids: transaction_ids)

    raise
  end
end
