class Goal < ApplicationRecord
  include Monetizable

  belongs_to :family
  has_many :budget_categories, dependent: :nullify

  validates :name, presence: true
  validates :target_amount, presence: true, numericality: { greater_than: 0 }
  validates :goal_type, presence: true, inclusion: { in: ->(_) { GOAL_TYPES.keys } }
  validates :currency, presence: true

  monetize :target_amount, :current_amount, :computed_current_amount, :remaining_amount

  GOAL_TYPES = {
    "emergency_fund" => { icon: "shield", color: "#ef4444" },
    "vacation" => { icon: "plane", color: "#3b82f6" },
    "home_down_payment" => { icon: "home", color: "#f59e0b" },
    "car" => { icon: "car", color: "#8b5cf6" },
    "debt_payoff" => { icon: "credit-card", color: "#ec4899" },
    "education" => { icon: "graduation-cap", color: "#06b6d4" },
    "retirement" => { icon: "sun", color: "#f97316" },
    "investment" => { icon: "trending-up", color: "#10b981" },
    "custom" => { icon: "target", color: "#6366f1" }
  }.freeze

  scope :active, -> { where(is_completed: false) }
  scope :completed, -> { where(is_completed: true) }
  scope :by_priority, -> { order(priority: :desc, created_at: :desc) }

  def computed_current_amount
    if linked_budget_categories.any?
      linked_budget_categories.sum { |bc| bc.budget.budget_category_actual_spending(bc) }
    else
      current_amount
    end
  end

  def progress_percent
    return 0 if target_amount.zero?
    [(computed_current_amount / target_amount.to_f * 100), 100].min
  end

  def remaining_amount
    [target_amount - computed_current_amount, 0].max
  end

  def on_track?
    return true if is_completed
    return true unless target_date

    days_total = (target_date - created_at.to_date).to_f
    return progress_percent >= 100 if days_total <= 0

    days_elapsed = (Date.current - created_at.to_date).to_f
    expected_progress = (days_elapsed / days_total) * 100
    progress_percent >= (expected_progress * 0.9)
  end

  def days_remaining
    return 0 unless target_date
    [(target_date - Date.current).to_i, 0].max
  end

  def goal_type_icon
    GOAL_TYPES.dig(goal_type, :icon) || "target"
  end

  def goal_type_color
    GOAL_TYPES.dig(goal_type, :color) || "#6366f1"
  end

  private

    def linked_budget_categories
      @linked_budget_categories ||= budget_categories.includes(:budget, :category).to_a
    end

    def monetizable_currency
      currency
    end
end
