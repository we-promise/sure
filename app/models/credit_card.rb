class CreditCard < ApplicationRecord
  include Accountable

  DEFAULT_SUBTYPE = "credit_card"

  SUBTYPES = {
    "credit_card" => { short: "Credit Card", long: "Credit Card" }
  }.freeze

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

    # The outstanding debt on a card whose provider reports the remaining
    # available credit instead of the balance owed. nil when there is no
    # positive limit, because the debt is then unknown. An overpaid card
    # reports more than its limit: clamp_overpayment turns that into zero
    # debt, otherwise it stays a negative (credit) balance.
    def debt_from_available_credit(credit_limit:, available_credit:, clamp_overpayment:)
      return nil unless credit_limit&.positive?

      debt = credit_limit - available_credit
      clamp_overpayment ? [ debt, 0 ].max : debt
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
end
