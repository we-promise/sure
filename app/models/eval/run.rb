class Eval::Run < ApplicationRecord
  self.table_name = "eval_runs"

  belongs_to :dataset, class_name: "Eval::Dataset", foreign_key: :eval_dataset_id
  has_many :results, class_name: "Eval::Result", foreign_key: :eval_run_id, dependent: :destroy

  validates :provider, :model, :status, presence: true
  validates :status, inclusion: { in: %w[pending running completed failed] }

  scope :pending, -> { where(status: "pending") }
  scope :running, -> { where(status: "running") }
  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
  scope :for_model, ->(model) { where(model: model) }
  scope :for_provider, ->(provider) { where(provider: provider) }

  # Calculate duration in seconds
  def duration_seconds
    return nil unless started_at && completed_at
    (completed_at - started_at).to_i
  end

  # Get accuracy from metrics or calculate
  def accuracy
    metrics.dig("accuracy") || calculate_accuracy
  end

  # Start the evaluation run
  def start!
    update!(status: "running", started_at: Time.current)
  end

  # Complete the evaluation run with metrics
  def complete!(calculated_metrics)
    update!(
      status: "completed",
      completed_at: Time.current,
      metrics: calculated_metrics,
      total_prompt_tokens: results.sum(:prompt_tokens),
      total_completion_tokens: results.sum(:completion_tokens),
      total_cost: results.sum(:cost)
    )
  end

  # Fail the evaluation run
  def fail!(error)
    update!(
      status: "failed",
      completed_at: Time.current,
      error_message: error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
    )
  end

  # Summary for display
  def summary
    {
      id: id,
      name: name,
      dataset: dataset.name,
      model: model,
      provider: provider,
      status: status,
      accuracy: accuracy,
      total_cost: total_cost&.to_f,
      duration: duration_seconds,
      samples_processed: results.count,
      samples_correct: results.where(correct: true).count,
      created_at: created_at
    }
  end

  # Compare this run to another
  def compare_to(other_run)
    {
      accuracy_diff: (accuracy || 0) - (other_run.accuracy || 0),
      cost_diff: (total_cost || 0) - (other_run.total_cost || 0),
      this_model: model,
      other_model: other_run.model
    }
  end

  private

    def calculate_accuracy
      return 0.0 if results.empty?
      (results.where(correct: true).count.to_f / results.count * 100).round(2)
    end
end
