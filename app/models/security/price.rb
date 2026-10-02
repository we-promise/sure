class Security::Price < ApplicationRecord
  belongs_to :security

  validates :date, :price, :currency, presence: true
  validates :date, uniqueness: { scope: %i[security_id currency] }
  validate :currency_is_known

  before_validation :normalize_currency, if: -> { new_record? || will_save_change_to_currency? }

  scope :with_known_currency, -> { where("UPPER(security_prices.currency) IN (?)", Money::Currency.all.keys.map(&:upcase)) }
  scope :with_unknown_currency, -> { where.not(id: with_known_currency.select(:id)) }
  scope :requiring_currency_retry, -> { where(currency_retry_required: true) }
  scope :with_unrecovered_currency, -> {
    with_unknown_currency.where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM (#{with_known_currency.where(currency_retry_required: false).select(:security_id, :date).to_sql}) recovered_prices
        WHERE recovered_prices.security_id = security_prices.security_id
          AND recovered_prices.date = security_prices.date
      )
    SQL
  }

  # Return the normalized ISO code only when the currency registry recognizes it.
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
    # Normalize recognized codes while leaving rejected input available to validation.
    def normalize_currency
      self.currency = currency.to_s.strip.upcase if currency.present?
    end

    # Reject unknown currencies before they can enter shared price history.
    def currency_is_known
      errors.add(:currency, :invalid) if currency.present? && self.class.normalized_currency(currency).nil?
    end
end
