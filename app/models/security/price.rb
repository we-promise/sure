class Security::Price < ApplicationRecord
  belongs_to :security

  validates :date, :price, :currency, presence: true
  validates :date, uniqueness: { scope: %i[security_id currency] }

  # Provisional prices from recent days that should be re-fetched
  # - Must be provisional (gap-filled)
  # - Must be from the last few days (configurable, default 7)
  # - Includes weekends: they get fixed via cascade when weekday prices are fetched
  scope :refetchable_provisional, ->(lookback_days: 7) {
    where(provisional: true)
      .where(date: lookback_days.days.ago.to_date..Date.current)
  }
end
