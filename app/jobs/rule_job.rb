class RuleJob < ApplicationJob
  queue_as :medium_priority

  def perform(rule, ignore_attribute_locks: false, execution_type: "manual")
    executed_at = Time.current
    transactions_queued = 0
    transactions_processed = 0
    transactions_modified = 0
    status = "success"
    error_message = nil

    begin
      # Count matching transactions before processing (queued count)
      transactions_queued = rule.affected_resource_count

      # Apply the rule and get the count of actually modified transactions
      modifications_count = rule.apply(ignore_attribute_locks: ignore_attribute_locks)

      # For synchronous executors: processed = modified (actual changes)
      # For async executors (AI): the count represents transactions queued for background processing
      transactions_processed = modifications_count
      transactions_modified = modifications_count
    rescue => e
      status = "failed"
      error_message = "#{e.class}: #{e.message}"
      Rails.logger.error("RuleJob failed for rule #{rule.id}: #{error_message}")
      raise # Re-raise to mark job as failed in Sidekiq
    ensure
      # Record the rule run
      RuleRun.create!(
        rule: rule,
        execution_type: execution_type,
        status: status,
        transactions_queued: transactions_queued,
        transactions_processed: transactions_processed,
        transactions_modified: transactions_modified,
        executed_at: executed_at,
        error_message: error_message
      )
    end
  end
end
