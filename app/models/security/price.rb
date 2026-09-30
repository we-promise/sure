class Security::Price < ApplicationRecord
  belongs_to :security

  validates :date, :price, :currency, presence: true
  validates :date, uniqueness: { scope: %i[security_id currency] }
  validate :currency_is_known

  before_validation :normalize_currency, if: -> { new_record? || will_save_change_to_currency? }

  scope :with_known_currency, -> { where("UPPER(security_prices.currency) IN (?)", Money::Currency.all.keys.map(&:upcase)) }

  def self.normalized_currency(code)
    Money::Currency.all[code.to_s.strip.downcase]&.fetch("iso_code")
  end

  # Provisional prices from recent days that should be re-fetched
  # - Must be provisional (gap-filled)
  # - Must be from the last few days (configurable, default 7)
  # - Includes weekends: they get fixed via cascade when weekday prices are fetched
  scope :refetchable_provisional, ->(lookback_days: 7) {
    where(provisional: true)
      .where(date: lookback_days.days.ago.to_date..Date.current)
  }

  private
    def normalize_currency
      self.currency = currency.to_s.strip.upcase if currency.present?
    end

    def currency_is_known
      errors.add(:currency, :invalid) if currency.present? && self.class.normalized_currency(currency).nil?
    end
end
