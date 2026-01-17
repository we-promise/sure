class AutoCategorizeJob < ApplicationJob
  queue_as :medium_priority

  def perform(family, transaction_ids: [], rule_run_id: nil)
    result = family.auto_categorize_transactions(transaction_ids)

    # If this job was part of a rule run, report back the modified count and metadata
    if rule_run_id.present?
      rule_run = RuleRun.find_by(id: rule_run_id)

      # Extract modified count and metadata from result
      # Result can be either an integer (legacy) or a Result struct with metadata
      if result.respond_to?(:modified_count)
        modified_count = result.modified_count
        metadata = result.metadata
      else
        modified_count = result.to_i
        metadata = nil
      end

      rule_run&.complete_job!(modified_count: modified_count, metadata: metadata)
    end
  end
end
