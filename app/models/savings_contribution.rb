class SavingsContribution < ApplicationRecord
  include Monetizable

  SOURCES = %w[initial manual auto].freeze

  belongs_to :savings_goal
  belongs_to :budget, optional: true

  has_one :family, through: :savings_goal

  validates :amount, presence: true, numericality: true
  validates :currency, presence: true
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :contributed_at, presence: true
  validate :budget_required_for_auto_source

  monetize :amount

  scope :auto, -> { where(source: "auto") }
  scope :manual, -> { where(source: "manual") }
  scope :initial, -> { where(source: "initial") }
  scope :chronological, -> { order(contributed_at: :asc, created_at: :asc) }
  scope :recent_first, -> { order(contributed_at: :desc, created_at: :desc) }

  private
    def budget_required_for_auto_source
      return unless source == "auto"
      errors.add(:budget, "must be set when source is auto") if budget_id.blank?
    end
end
