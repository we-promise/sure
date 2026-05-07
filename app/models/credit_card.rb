class CreditCard < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "credit_card" => { short: "Credit Card", long: "Credit Card" }
  }.freeze

  validate :expiration_date_not_in_past

  class << self
    def color
      "#F13636"
    end

    def icon
      "credit-card"
    end

    def classification
      "liability"
    end
  end

  def available_credit_money
    available_credit ? Money.new(available_credit, account.currency) : nil
  end

  def minimum_payment_money
    minimum_payment ? Money.new(minimum_payment, account.currency) : nil
  end

  def annual_fee_money
    annual_fee ? Money.new(annual_fee, account.currency) : nil
  end

  private

    def expiration_date_not_in_past
      return if expiration_date.blank?
      return if expiration_date >= Date.current

      errors.add(:expiration_date, :greater_than_or_equal_to, count: Date.current)
    end
end
