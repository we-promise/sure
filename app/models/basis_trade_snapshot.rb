class BasisTradeSnapshot < ApplicationRecord
  belongs_to :family

  validates :recorded_at, :currency, presence: true
  validates :recorded_at, uniqueness: { scope: :family_id }
  validates :spot_leg_cents, :short_leg_cents, :funding_accrued_cents, :rewards_accrued_cents,
            numericality: { only_integer: true }

  scope :for_family, ->(family) { where(family: family) }
  scope :chronological, -> { order(:recorded_at) }
  scope :between, ->(start_at, end_at) { where(recorded_at: start_at..end_at) }
end
