class SavingGoal < ApplicationRecord
  include Monetizable

  class InvalidTransitionError < StandardError; end

  belongs_to :family
  has_many :saving_contributions, dependent: :destroy, autosave: true

  monetize :target_amount, :current_amount, :remaining_amount

  enum :status, { active: "active", paused: "paused", completed: "completed", archived: "archived" }, default: :active

  validates :name, presence: true
  validates :target_amount, numericality: { greater_than: 0 }
  validates :current_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true

  COLORS = %w[blue green indigo purple pink red orange yellow zinc].freeze
  validates :color, inclusion: { in: COLORS }, allow_nil: true

  scope :active, -> { where(status: :active) }

  # Calculates the percentage of the goal completed (0-100).
  def progress_percent
    return 0 if target_amount.nil? || target_amount.zero?
    return 100 if current_amount >= target_amount

    (current_amount / target_amount * 100).round(2)
  end

  # Returns the remaining amount needed to reach the target.
  # Returns 0 if current_amount >= target_amount.
  def remaining_amount
    return 0 if target_amount.nil?
    [ target_amount - current_amount, 0 ].max
  end

  # Checks if the saving goal is on track based on expected progress over time.
  # Allows for a 5% tolerance.
  def on_track?
    return true if target_date.nil?
    return true if current_amount >= target_amount
    return true if status == "completed"

    actual = progress_percent
    expected = expected_progress_percent

    # 5% tolerance
    actual >= (expected - 5)
  end

  # Calculates the monthly amount needed to reach the goal by the target date.
  def monthly_target
    return nil if target_date.nil?

    months = months_remaining
    return remaining_amount_for_month if months < 1

    (remaining_amount_for_month / months).round(2)
  end

  # Remaining amount for this month excluding current monthly contributions.
  # This represents the "effort" still needed for the current month.
  def remaining_amount_for_month
    this_month_contribution = saving_contributions
      .where(month: Date.current.beginning_of_month)
      .where.not(source: :initial_balance)
      .sum(:amount)

    [ target_amount - (current_amount - this_month_contribution), 0 ].max
  end

  # Calculates the number of months remaining until the target date.
  def months_remaining
    return nil if target_date.nil?
    (target_date.year * 12 + target_date.month) - (Date.current.year * 12 + Date.current.month) + 1
  end

  # Transitions the goal status to paused.
  def pause!
    raise InvalidTransitionError, "Can only pause active goals" unless active?
    update!(status: :paused)
  end

  # Transitions the goal status back to active.
  def resume!
    raise InvalidTransitionError, "Can only resume paused goals" unless paused?
    update!(status: :active)
  end

  # Marks the goal as completed.
  def complete!
    raise InvalidTransitionError, "Can not complete archived goals" if archived?
    update!(status: :completed)
  end

  # hives the goal, removing it from active lists.
  def archive!
    raise InvalidTransitionError, "Already archived" if archived?
    update!(status: :archived)
  end

  private

    def expected_progress_percent
      return 0 unless created_at && target_date

      total_days = (target_date - created_at.to_date).to_f
      return 100 if total_days <= 0

      days_elapsed = (Date.current - created_at.to_date).to_f

      (days_elapsed / total_days * 100).clamp(0, 100)
    end
end
