class ExchangeRate < ApplicationRecord
  include Provided

  # Part of the cache key of every cached figure converted into the family
  # currency. Those keys follow entries and syncs, not the conversion rule, so
  # a change to the rule bumps this or old figures outlive the deploy.
  # "fx2": a missing rate is no longer counted as 1 (#3640).
  CONVERSION_CACHE_VERSION = "fx2"

  validates :from_currency, :to_currency, :date, :rate, presence: true
  validates :date, uniqueness: { scope: %i[from_currency to_currency] }
end
