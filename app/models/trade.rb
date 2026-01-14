class Trade < ApplicationRecord
  include Entryable, Monetizable

  monetize :price

  belongs_to :security

  # Use the same activity labels as Transaction
  ACTIVITY_LABELS = Transaction::ACTIVITY_LABELS.dup

  validates :qty, presence: true
  validates :price, :currency, presence: true
  validates :investment_activity_label, inclusion: { in: ACTIVITY_LABELS }, allow_nil: true

  # Trade types for categorization
  def buy?
    qty.positive?
  end

  def sell?
    qty.negative?
  end

  class << self
    def build_name(type, qty, ticker)
      prefix = type == "buy" ? "Buy" : "Sell"
      "#{prefix} #{qty.to_d.abs} shares of #{ticker}"
    end
  end

  def unrealized_gain_loss
    return nil if qty.negative?
    current_price = security.current_price
    return nil if current_price.nil?

    current_value = current_price * qty.abs
    cost_basis = price_money * qty.abs

    Trend.new(current: current_value, previous: cost_basis)
  end

  # Trades are always excluded from expense budgets
  # They represent portfolio management, not living expenses
  def excluded_from_budget?
    true
  end
end
