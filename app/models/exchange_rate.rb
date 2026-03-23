class ExchangeRate < ApplicationRecord
  include Provided

  validates :from_currency, :to_currency, :date, :rate, presence: true
  validates :rate, numericality: { greater_than: 0 }
  validates :date, uniqueness: { scope: %i[from_currency to_currency] }
end
