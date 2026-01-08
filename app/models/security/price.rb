class Security::Price < ApplicationRecord
  belongs_to :security

  validates :date, :price, :currency, presence: true
  validates :date, uniqueness: { scope: %i[security_id currency] }

  # Provisional prices from recent weekdays that should be re-fetched
  # - Must be provisional (gap-filled)
  # - Must be from the last few days (configurable, default 3)
  # - Must be a weekday (Saturday = 6, Sunday = 0 in PostgreSQL DOW)
  scope :refetchable_provisional, ->(lookback_days: 3) {
    where(provisional: true)
      .where(date: lookback_days.days.ago.to_date..Date.current)
      .where("EXTRACT(DOW FROM date) NOT IN (0, 6)")
  }
end
