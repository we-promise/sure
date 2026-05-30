class Goal::RetirementAdjustment < ApplicationRecord
  include Monetizable

  self.table_name = "goal_retirement_adjustments"

  belongs_to :goal_retirement, class_name: "Goal::Retirement", foreign_key: :goal_retirement_id

  validates :from_age, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 120 }
  validates :to_age,
    numericality: { only_integer: true, greater_than: :from_age, less_than_or_equal_to: 120 },
    allow_nil: true
  # Signed: negative reduces target spend in retirement, positive raises it.
  validates :amount_today, presence: true, numericality: true
  validates :currency, presence: true
  validates :label, presence: true, length: { maximum: 255 }
  validates :ordinal, presence: true, numericality: { only_integer: true }
  # The cap also lives on Goal::Retirement, but parent validations don't run
  # when a child is saved directly (the CRUD path), so enforce it here too.
  validate :within_plan_limit, on: :create

  scope :ordered, -> { order(:ordinal, :created_at) }

  monetize :amount_today

  def applicable_at?(age)
    return false if age < from_age
    to_age.nil? || age <= to_age
  end

  private
    def within_plan_limit
      return if goal_retirement.nil?
      return if goal_retirement.adjustments.where.not(id: id).count < Goal::Retirement::ADJUSTMENTS_LIMIT

      errors.add(:base, :limit_reached, count: Goal::Retirement::ADJUSTMENTS_LIMIT)
    end
end
