class Trade < ApplicationRecord
  include Entryable, Monetizable

  monetize :price
  monetize :fee

  belongs_to :security
  belongs_to :category, optional: true

  # Use the same activity labels as Transaction
  ACTIVITY_LABELS = Transaction::ACTIVITY_LABELS.dup.freeze

  validates :qty, presence: true
  validates :price, :currency, presence: true
  validates :investment_activity_label, inclusion: { in: ACTIVITY_LABELS }, allow_nil: true

  def exchange_rate
    extra&.dig("exchange_rate")
  end

  def exchange_rate=(value)
    if value.blank?
      self.extra = (extra || {}).merge("exchange_rate" => nil, "exchange_rate_invalid" => false)
    else
      begin
        normalized_value = Float(value)
        raise ArgumentError unless normalized_value.finite?

        self.extra = (extra || {}).merge("exchange_rate" => normalized_value, "exchange_rate_invalid" => false)
      rescue ArgumentError, TypeError
        self.extra = (extra || {}).merge("exchange_rate" => value, "exchange_rate_invalid" => true)
      end
    end
  end

  validate :exchange_rate_must_be_valid

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
    return nil unless qty.positive?
    current_price = security.current_price
    return nil if current_price.nil?

    current_value = current_price * qty.abs
    cost_basis = price_money * qty.abs

    Trend.new(current: current_value, previous: cost_basis)
  end

  # Calculates realized gain/loss for sell trades based on avg_cost at time of sale
  # Returns nil for buy trades or when cost basis cannot be determined
  def realized_gain_loss
    return @realized_gain_loss if defined?(@realized_gain_loss)

    @realized_gain_loss = calculate_realized_gain_loss
  end

  # Trades are always excluded from expense budgets
  # They represent portfolio management, not living expenses
  def excluded_from_budget?
    true
  end

  private

    def exchange_rate_must_be_valid
      if extra&.dig("exchange_rate_invalid")
        errors.add(:exchange_rate, "must be a number")
      elsif exchange_rate.present?
        numeric_rate = Float(exchange_rate) rescue nil
        if numeric_rate.nil? || !numeric_rate.finite? || numeric_rate <= 0
          errors.add(:exchange_rate, "must be greater than 0")
        end
      end
    end

    def calculate_realized_gain_loss
      return nil unless sell?

      # Use preloaded holdings if available (set by reports controller to avoid N+1)
      # Treat defined-but-empty preload as authoritative to prevent DB fallback
      holding = if defined?(@preloaded_holdings)
        # Use select + max_by for deterministic selection regardless of array order
        (@preloaded_holdings || [])
          .select { |h| h.security_id == security_id && h.date <= entry.date }
          .max_by(&:date)
      else
        # Fall back to database query only when not preloaded
        entry.account.holdings
          .where(security_id: security_id)
          .where("date <= ?", entry.date)
          .order(date: :desc)
          .first
      end

      return nil unless holding&.avg_cost

      cost_basis = holding.avg_cost * qty.abs
      sale_proceeds = price_money * qty.abs

      Trend.new(current: sale_proceeds, previous: cost_basis)
    end
end
