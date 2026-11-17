class RuleRun < ApplicationRecord
  belongs_to :rule

  validates :execution_type, inclusion: { in: %w[manual scheduled] }
  validates :status, inclusion: { in: %w[pending success failed] }
  validates :executed_at, presence: true
  validates :transactions_queued, numericality: { greater_than_or_equal_to: 0 }
  validates :transactions_processed, numericality: { greater_than_or_equal_to: 0 }
  validates :transactions_modified, numericality: { greater_than_or_equal_to: 0 }
  validates :pending_jobs_count, numericality: { greater_than_or_equal_to: 0 }
  validates :transactions_awaiting_ai, numericality: { greater_than_or_equal_to: 0 }

  scope :recent, -> { order(executed_at: :desc) }
  scope :for_rule, ->(rule) { where(rule: rule) }
  scope :for_family, ->(family) { joins(:rule).where(rules: { family_id: family.id }) }
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

  # A failure is recorded as soon as one job fails, so the run is finished only once no job is
  # left to change its counts.
  def finished? = !pending? && pending_jobs_count.zero?

  def transactions_blocked
    [ transactions_processed - transactions_modified, 0 ].max
  end

  # Before an AI job is queued: `count` more transactions wait for an answer. Atomic, so it holds
  # however soon the job starts.
  def await_ai!(count) = self.class.update_counters(id, transactions_awaiting_ai: count)

  # An AI job is done with `handled` of its transactions (applied, skipped or given up on), and
  # `modified` of them changed. Called per batch, so a client can watch the run count down.
  def ai_handled!(handled:, modified: 0)
    return if handled.zero? && modified.zero?

    save_locked do
      self.transactions_modified += modified
      self.transactions_awaiting_ai = [ transactions_awaiting_ai - handled, 0 ].max
    end
  end

  # Thread-safe method to complete a job and update the run
  def complete_job!(modified_count: 0)
    save_locked do
      self.transactions_modified += modified_count
      self.pending_jobs_count = [ pending_jobs_count - 1, 0 ].max

      # Preserve a previously recorded failure while still draining pending jobs.
      self.status = "success" if pending_jobs_count <= 0 && !failed?
    end
  end

  def fail_job!(error:, source:, transaction_ids: [])
    should_log = false
    current_error_message = "#{error.class}: #{error.message}"

    save_locked do
      should_log = !failed?

      self.pending_jobs_count = [ pending_jobs_count - 1, 0 ].max
      self.status = "failed"
      existing_error_messages = error_message.to_s.split("\n").reject(&:blank?)
      self.error_message = (existing_error_messages + [ current_error_message ]).uniq.join("\n")
    end

    capture_failure_debug_log(error:, source:, transaction_ids:) if should_log
  end

  private
    # Changes the run under its row lock and saves it. A failed save, or a save whose enclosing
    # transaction rolled back, leaves its changes on the record, and Rails refuses to lock a record
    # with unsaved changes, so they're discarded: the next update (often the failure's own) can
    # still take the lock. In memory, not by reloading: after a deadlock the transaction is
    # aborted, and a query would replace the retryable error. with_lock reloads the row anyway.
    def save_locked
      restore_attributes
      with_lock do
        yield
        save!
      end
    rescue StandardError
      restore_attributes
      raise
    end

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
