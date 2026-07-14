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
      increment!(:transactions_modified, modified_count)
      decrement!(:pending_jobs_count)

      # Preserve a previously recorded failure while still draining pending jobs.
      if pending_jobs_count <= 0
        update!(status: "success") unless failed?
      end
    end
  end

  def fail_job!(error_message:)
    with_lock do
      decrement!(:pending_jobs_count) if pending_jobs_count.positive?

      combined_error_message = [ self.error_message.presence, error_message.presence ]
        .compact
        .uniq
        .join("\n")

      update!(
        status: "failed",
        error_message: combined_error_message
      )
    end
  end
end
