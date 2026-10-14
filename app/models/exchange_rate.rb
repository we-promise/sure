class ExchangeRate < ApplicationRecord
  include Provided

  # Part of the cache key of every cached figure converted into the family
  # currency. Those keys follow entries and syncs, not the conversion rule, so
  # a change to the rule bumps this or old figures outlive the deploy.
  # "fx2": a missing rate is no longer counted as 1 (#3640).
  CONVERSION_CACHE_VERSION = "fx2"

  validates :from_currency, :to_currency, :date, :rate, presence: true
  validates :date, uniqueness: { scope: %i[from_currency to_currency] }
  validate :rate_must_convert_amounts, if: -> { rate.present? }

  # A rate multiplies an amount into another currency, so only a finite,
  # positive number is usable. A zero turns every converted balance into zero
  # (we-promise/sure#1187); negative, NaN or infinite rates are just as wrong.
  #
  # The chk_exchange_rates_rate_positive database constraint enforces the same
  # rule for writes that skip validations, such as the importer's upsert_all.
  def self.valid_rate?(value)
    number = value.is_a?(Numeric) ? value : BigDecimal(value.to_s)
    number.finite? && number.positive?
  rescue ArgumentError, TypeError
    false
  end

  private
    def rate_must_convert_amounts
      errors.add(:rate, :greater_than, count: 0) unless self.class.valid_rate?(rate)
    end
end
