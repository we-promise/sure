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

  def progress_percent
    return 0 if target_amount.nil? || target_amount.zero?
    return 100 if current_amount >= target_amount

    (current_amount / target_amount * 100).round(2)
  end

  def remaining_amount
    return 0 if target_amount.nil?
    [ target_amount - current_amount, 0 ].max
  end

  def on_track?
    return true if target_date.nil?
    return true if current_amount >= target_amount
    return true if status == "completed"

    actual = progress_percent
    expected = expected_progress_percent

    # 5% tolerance
    actual >= (expected - 5)
  end

  def monthly_target
    return nil if target_date.nil?

    months = months_remaining
    return remaining_amount_for_month if months < 1

    (remaining_amount_for_month / months).round(2)
  end

  # Remaining amount excluding current month's contribution (if any)
  # This gives the "effort" needed for the current month
  def remaining_amount_for_month
    this_month_contribution = saving_contributions
      .where(month: Date.current.beginning_of_month)
      .where.not(source: :initial_balance)
      .sum(:amount)

    [ target_amount - (current_amount - this_month_contribution), 0 ].max
  end

  def months_remaining
    return nil if target_date.nil?
    (target_date.year * 12 + target_date.month) - (Date.current.year * 12 + Date.current.month) + 1
  end

  def pause!
    raise InvalidTransitionError, "Can only pause active goals" unless active?
    update!(status: :paused)
  end

  def resume!
    raise InvalidTransitionError, "Can only resume paused goals" unless paused?
    update!(status: :active)
  end

  def complete!
    raise InvalidTransitionError, "Can not complete archived goals" if archived?
    update!(status: :completed)
  end

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
