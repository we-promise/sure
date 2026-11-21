# carried_forward: the importer filled this date by repeating an earlier
# price; a real quote is carried_forward: false. provisional: a recent
# carried-forward price the importer asks the provider for again. Every
# provisional row is carried forward (provisional rows stored before the
# column existed were backfilled), so readers of real quotes filter on
# carried_forward alone.
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
