class AutoCategorizeJob < ApplicationJob
  queue_as :ai_low_priority

  # recheck_eligibility: the API endpoint filters what it queues, but a
  # transaction can become a transfer leg (transfer matching runs on account
  # sync) or a split parent, or get a category by hand, before this low
  # priority job runs; those are dropped here instead of categorized. With
  # user_id (the API caller), access is rechecked too: an account share revoked
  # after queueing, or a deleted user, drops those transactions.
  def perform(family, transaction_ids: [], rule_run_id: nil, recheck_eligibility: false, user_id: nil)
    if recheck_eligibility
      scope = if user_id.present?
        user = family.users.find_by(id: user_id)
        user ? family.auto_categorizable_transactions_for(user) : Transaction.none
      else
        family.auto_categorizable_transactions
      end
      transaction_ids = scope.where(id: transaction_ids).pluck(:id)
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
