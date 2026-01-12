class Holding < ApplicationRecord
  include Monetizable, Gapfillable

  monetize :amount

  belongs_to :account
  belongs_to :security
  belongs_to :account_provider, optional: true

  validates :qty, :currency, :date, :price, :amount, presence: true
  validates :qty, :price, :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :external_id, uniqueness: { scope: :account_id }, allow_blank: true

  scope :chronological, -> { order(:date) }
  scope :for, ->(security) { where(security_id: security).order(:date) }

  delegate :ticker, to: :security

  def name
    security.name || ticker
  end

  def weight
    return nil unless amount
    return 0 if amount.zero?

    account.balance.zero? ? 1 : amount / account.balance * 100
  end

  # Returns average cost per share, or nil if unknown.
  #
  # Uses pre-computed cost_basis if available (set during materialization),
  # otherwise falls back to calculating from trades. Returns nil when cost
  # basis cannot be determined (no trades and no provider cost_basis).
  def avg_cost
    # Use stored cost_basis if available and positive (eliminates N+1 queries)
    # Note: cost_basis of 0 is treated as "unknown" since providers sometimes
    # return 0 when they don't have the data
    return Money.new(cost_basis, currency) if cost_basis.present? && cost_basis.positive?

    # Fallback to calculation for holdings without pre-computed cost_basis
    calculate_avg_cost
  end

  def trend
    @trend ||= calculate_trend
  end

  # Day change based on previous holding snapshot (same account/security/currency)
  # Returns a Trend struct similar to other trend usages or nil if no prior snapshot.
  def day_change
    # Memoize even when nil to avoid repeated queries during a request lifecycle
    return @day_change if instance_variable_defined?(:@day_change)

    return (@day_change = nil) unless amount_money

    prev = account.holdings
                 .where(security_id: security_id, currency: currency)
                 .where("date < ?", date)
                 .order(date: :desc)
                 .first

    @day_change = prev&.amount_money ? Trend.new(current: amount_money, previous: prev.amount_money) : nil
  end

  def trades
    account.entries.where(entryable: account.trades.where(security: security)).reverse_chronological
  end

  def destroy_holding_and_entries!
    transaction do
      account.entries.where(entryable: account.trades.where(security: security)).destroy_all
      destroy
    end

    account.sync_later
  end

  private
    def calculate_trend
      return nil unless amount_money
      return nil unless avg_cost # Can't calculate trend without cost basis

      start_amount = qty * avg_cost

      Trend.new \
        current: amount_money,
        previous: start_amount
    end

    # Calculates weighted average cost from buy trades.
    # Returns nil if no trades exist (cost basis is unknown).
    def calculate_avg_cost
      trades = account.trades
        .with_entry
        .joins(ActiveRecord::Base.sanitize_sql_array([
          "LEFT JOIN exchange_rates ON (
            exchange_rates.date = entries.date AND
            exchange_rates.from_currency = trades.currency AND
            exchange_rates.to_currency = ?
          )", account.currency
        ]))
        .where(security_id: security.id)
        .where("trades.qty > 0 AND entries.date <= ?", date)

      total_cost, total_qty = trades.pick(
        Arel.sql("SUM(trades.price * trades.qty * COALESCE(exchange_rates.rate, 1))"),
        Arel.sql("SUM(trades.qty)")
      )

      # Return nil when no trades exist - cost basis is genuinely unknown
      # Previously this fell back to current market price, which was misleading
      return nil unless total_qty && total_qty > 0

      Money.new(total_cost / total_qty, currency)
    end
end
