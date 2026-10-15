# Daily commodity price per troy ounce, independent of Security::Price.
class Commodity::Price < ApplicationRecord
  include Provided

  # Higher-ranked sources win when two report the same day: spot over futures.
  SOURCES = %w[gold_api yahoo_futures].freeze
  # Days a missing price is carried forward when reading (weekends, holidays).
  LOOKBACK_DAYS = 7

  validates :code, :date, :currency, presence: true
  validates :price, numericality: { greater_than: 0 }
  validates :source, inclusion: { in: SOURCES }
  validates :date, uniqueness: { scope: %i[code currency] }

  scope :refetchable_provisional, ->(lookback_days: LOOKBACK_DAYS) {
    where(provisional: true).where(date: lookback_days.days.ago.to_date..Date.current)
  }

  class << self
    # Latest stored price on or before `date`, as Money per troy ounce converted
    # to `currency` at that date's rate. nil when no price or no FX rate exists.
    def per_troy_ounce(code, date:, currency:)
      row = latest_on(code, date)
      return nil unless row

      Money.new(row.price, row.currency).exchange_to(currency, date: date)
    rescue Money::ConversionError
      nil
    end

    def latest_on(code, date)
      where(code: code, date: (date - LOOKBACK_DAYS)..date).order(date: :desc).first
    end
  end

  def futures?
    source == "yahoo_futures"
  end
end
