class RuleRun < ApplicationRecord
  belongs_to :rule

  validates :execution_type, inclusion: { in: %w[manual scheduled] }
  validates :status, inclusion: { in: %w[pending success failed] }
  validates :executed_at, presence: true
  validates :transactions_queued, numericality: { greater_than_or_equal_to: 0 }
  validates :transactions_processed, numericality: { greater_than_or_equal_to: 0 }
  validates :transactions_modified, numericality: { greater_than_or_equal_to: 0 }
  validates :pending_jobs_count, numericality: { greater_than_or_equal_to: 0 }

  scope :recent, -> { order(executed_at: :desc) }
  scope :for_rule, ->(rule) { where(rule: rule) }
  scope :successful, -> { where(status: "success") }
  scope :failed, -> { where(status: "failed") }
  scope :pending, -> { where(status: "pending") }

  def pending?
    status == "pending"
  end

  def success?
    status == "success"
  end

  def failed?
    status == "failed"
  end

  def transactions_blocked
    [ transactions_processed - transactions_modified, 0 ].max
  end

  # Thread-safe method to complete a job and update the run
  def complete_job!(modified_count: 0)
    with_lock do
      self.transactions_modified += modified_count
      self.pending_jobs_count = [ pending_jobs_count - 1, 0 ].max

      # If all jobs are done, mark as success
      self.status = "success" if pending_jobs_count <= 0 && !failed?

      save!
    end
  end

  def fail_job!(error:, source:, transaction_ids: [])
    should_log = false

    with_lock do
      should_log = !failed?

      self.pending_jobs_count = [ pending_jobs_count - 1, 0 ].max
      self.status = "failed"
      self.error_message = "#{error.class}: #{error.message}"

      save!
    end

    capture_failure_debug_log(error:, source:, transaction_ids:) if should_log
  end

  private
    def capture_failure_debug_log(error:, source:, transaction_ids:)
      DebugLogEntry.capture(
        category: "rule_run",
        level: "error",
        message: "Rule run failed: #{error.class}: #{error.message}",
        source: source,
        family: rule.family,
        metadata: {
          rule_run_id: id,
          rule_id: rule_id,
          rule_name: rule_name,
          execution_type: execution_type,
          error_class: error.class.name,
          error_message: error.message,
          transaction_count: transaction_ids.size,
          transaction_ids: transaction_ids,
          backtrace: Array(error.backtrace).first(10)
        }
      )
    end
end
