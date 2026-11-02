class ExchangeRate < ApplicationRecord
  include Provided

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

  # When the rates converting into +to+ last changed, for cache keys: a rate can
  # arrive without touching entries or accounts. Sub-second, as rates are written
  # in bursts and can land within the second a figure was cached. Scoped to the
  # target currency (index_exchange_rates_on_to_currency) rather than every rate;
  # +from+ narrows it to the pairs actually converted, and returns nil without a
  # query when none of them needs converting.
  def self.cache_version(to:, from: nil)
    scope = where(to_currency: to)
    unless from.nil?
      from = Array(from).compact.uniq - [ to ]
      return nil if from.empty?

      scope = scope.where(from_currency: from)
    end
    scope.maximum(:updated_at)&.to_f
  end

  private
    def rate_must_convert_amounts
      errors.add(:rate, :greater_than, count: 0) unless self.class.valid_rate?(rate)
    end
end
