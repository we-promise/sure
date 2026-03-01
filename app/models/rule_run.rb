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

  # Thread-safe method to complete a job and update the run
  # Accepts optional metadata hash to merge into run_metadata
  def complete_job!(modified_count: 0, metadata: nil)
    with_lock do
      increment!(:transactions_modified, modified_count)
      decrement!(:pending_jobs_count)

      # Merge provided metadata into run_metadata
      if metadata.present?
        merge_metadata!(metadata)
      end

      # If all jobs are done, mark as success
      if pending_jobs_count <= 0
        update!(status: "success")
      end
    end
  end

  # Merge metadata into run_metadata, combining values intelligently
  # - Arrays are concatenated
  # - Numbers are summed
  # - Hashes are deep merged
  # - Other values are overwritten
  def merge_metadata!(new_metadata)
    current = run_metadata || {}
    merged = deep_merge_metadata(current, new_metadata.deep_stringify_keys)
    update!(run_metadata: merged)
  end

  private

    def deep_merge_metadata(base, addition)
      base.merge(addition) do |_key, old_val, new_val|
        if old_val.is_a?(Hash) && new_val.is_a?(Hash)
          deep_merge_metadata(old_val, new_val)
        elsif old_val.is_a?(Array) && new_val.is_a?(Array)
          old_val + new_val
        elsif old_val.is_a?(Numeric) && new_val.is_a?(Numeric)
          old_val + new_val
        else
          new_val
        end
      end
    end
end
