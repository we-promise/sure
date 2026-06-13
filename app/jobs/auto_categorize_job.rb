class AutoCategorizeJob < ApplicationJob
  queue_as :medium_priority

  def perform(family, transaction_ids: [], rule_run_id: nil)
    modified_count = family.auto_categorize_transactions(transaction_ids)

    # If this job was part of a rule run, report back the modified count
    if rule_run_id.present?
      rule_run = RuleRun.find_by(id: rule_run_id)
      rule_run&.complete_job!(modified_count: modified_count)
    end
  rescue => error
    if rule_run_id.present?
      rule_run = RuleRun.find_by(id: rule_run_id)
      rule_run&.fail_job!(error_message: build_rule_run_error(error, family:, transaction_ids:))
    end

    raise
  end

  private

    def build_rule_run_error(error, family:, transaction_ids:)
      sample_ids = Array(transaction_ids).first(5).join(", ")
      context = "family=#{family.id} transaction_count=#{Array(transaction_ids).size}"
      context += " sample_transaction_ids=#{sample_ids}" if sample_ids.present?

      "Auto-categorization failed (#{context}): #{error.class}: #{error.message}"
    end
end
