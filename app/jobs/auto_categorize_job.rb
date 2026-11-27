class AutoCategorizeJob < ApplicationJob
  queue_as :ai_low_priority

  def perform(family, transaction_ids: [], rule_run_id: nil, exclude_transaction_ids: [], already_modified_count: 0)
    rule_run = RuleRun.find_by(id: rule_run_id) if rule_run_id.present?
    modified_transaction_ids = Set.new
    modified_count = Ai.available?(:categorize, family:) ? family.auto_categorize_transactions(
      transaction_ids,
      exclude_transaction_ids: exclude_transaction_ids,
      modified_transaction_ids: modified_transaction_ids
    ) : 0

    # If this job was part of a rule run, report back what it changed
    rule_run&.complete_job!(
      modified_count: modified_count,
      modified_transaction_ids: modified_transaction_ids,
      already_modified_count: already_modified_count
    )
  rescue => error
    rule_run&.fail_job!(
      error: error,
      source: self.class.name,
      transaction_ids: transaction_ids,
      already_modified_count: already_modified_count
    )

    raise
  end
end
