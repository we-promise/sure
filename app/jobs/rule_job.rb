class RuleJob < ApplicationJob
  queue_as :medium_priority

  def perform(rule, ignore_attribute_locks: false, execution_type: "manual")
    executed_at = Time.current
    transactions_queued = 0
    transactions_processed = 0
    transactions_modified = 0
    pending_jobs_count = 0
    status = "unknown"
    error_message = nil
    rule_run = nil

    begin
      # Count matching transactions before processing (queued count)
      transactions_queued = rule.affected_resource_count

      # Create the RuleRun record first with pending status
      # We'll update it after we know if there are async jobs
      # Store the rule name at execution time so it persists even if the rule name changes later
      rule_run = RuleRun.create!(
        rule: rule,
        rule_name: rule.name,
        execution_type: execution_type,
        status: "pending",  # Start as pending, will be updated
        transactions_queued: transactions_queued,
        transactions_processed: 0,
        transactions_modified: 0,
        pending_jobs_count: 0,
        executed_at: executed_at
      )

      # Apply the rule and get the result
      result = rule.apply(ignore_attribute_locks: ignore_attribute_locks, rule_run: rule_run)

      if result.is_a?(Hash) && result[:async]
        # Async actions were executed
        transactions_processed = result[:modified_count] || 0
        pending_jobs_count = result[:jobs_count] || 0
        status = "pending"
      elsif result.is_a?(Integer)
        # Only synchronous actions were executed
        transactions_processed = result
        transactions_modified = result
        status = "success"
      else
        # Unexpected result type - log and default to 0
        Rails.logger.warn("RuleJob: Unexpected result type from rule.apply: #{result.class} for rule #{rule.id}")
        transactions_processed = 0
        transactions_modified = 0
        status = "unknown"
      end

      # Update the rule run with final counts
      rule_run.update!(
        status: status,
        transactions_processed: transactions_processed,
        transactions_modified: transactions_modified,
        pending_jobs_count: pending_jobs_count
      )
    rescue => e
      status = "failed"
      error_message = "#{e.class}: #{e.message}"
      Rails.logger.error("RuleJob failed for rule #{rule.id}: #{error_message}")

      # Update the rule run as failed if it was created
      if rule_run
        rule_run.update(status: "failed", error_message: error_message)
      else
        # Create a failed rule run if we hadn't created one yet
        # Store the rule name at execution time so it persists even if the rule name changes later
        begin
          RuleRun.create!(
            rule: rule,
            rule_name: rule.name,
            execution_type: execution_type,
            status: "failed",
            transactions_queued: transactions_queued,
            transactions_processed: 0,
            transactions_modified: 0,
            pending_jobs_count: 0,
            executed_at: executed_at,
            error_message: error_message
          )
        rescue => e
          Rails.logger.error("RuleJob: Failed to create RuleRun for rule #{rule.id}: #{e.message}")
        end
      end

      raise # Re-raise to mark job as failed in Sidekiq
    end
  end
end
