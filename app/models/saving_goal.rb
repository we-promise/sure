class SavingGoal < ApplicationRecord
  include Monetizable

  belongs_to :family
  has_many :saving_contributions, dependent: :destroy

  monetize :target_amount, :current_amount

  enum :status, { active: "active", paused: "paused", completed: "completed", archived: "archived" }, default: :active

  validates :name, presence: true
  validates :target_amount, numericality: { greater_than: 0 }
  validates :current_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true

  scope :active, -> { where(status: :active) }
end
