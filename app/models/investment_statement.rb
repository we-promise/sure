require "digest/md5"

class InvestmentStatement
  include Monetizable

  monetize :total_contributions, :total_dividends, :total_interest, :unrealized_gains, :investment_only_value, :crypto_value

  attr_reader :family

  def initialize(family)
    @family = family
  end

  # Get totals for a specific period
  def totals(period: Period.current_month)
    trades_in_period = family.trades
      .joins(:entry)
      .where(entries: { date: period.date_range })

    result = totals_query(trades_scope: trades_in_period)

    PeriodTotals.new(
      contributions: Money.new(result[:contributions], family.currency),
      withdrawals: Money.new(result[:withdrawals], family.currency),
      dividends: Money.new(result[:dividends], family.currency),
      interest: Money.new(result[:interest], family.currency),
      trades_count: result[:trades_count],
      currency: family.currency
    )
  end

  # Net contributions (contributions - withdrawals)
  def net_contributions(period: Period.current_month)
    t = totals(period: period)
    t.contributions - t.withdrawals
  end

  # Total portfolio value across all investment accounts
  def portfolio_value
    investment_accounts.sum(&:balance)
  end

  def portfolio_value_money
    Money.new(portfolio_value, family.currency)
  end

  # Breakdown by account type
  def investment_only_value
    investment_accounts.select { |a| a.accountable_type == "Investment" }.sum(&:balance)
  end

  def crypto_value
    investment_accounts.select { |a| a.accountable_type == "Crypto" }.sum(&:balance)
  end

  def has_crypto?
    investment_accounts.any? { |a| a.accountable_type == "Crypto" }
  end

  def has_investments?
    investment_accounts.any? { |a| a.accountable_type == "Investment" }
  end

  # Total cash in investment accounts
  def cash_balance
    investment_accounts.sum(&:cash_balance)
  end

  def cash_balance_money
    Money.new(cash_balance, family.currency)
  end

  # Total holdings value
  def holdings_value
    portfolio_value - cash_balance
  end

  def holdings_value_money
    Money.new(holdings_value, family.currency)
  end

  # All current holdings across investment accounts
  def current_holdings
    return Holding.none unless investment_accounts.any?

    account_ids = investment_accounts.pluck(:id)

    # Get the latest holding for each security per account
    Holding
      .where(account_id: account_ids)
      .where(currency: family.currency)
      .where.not(qty: 0)
      .where(
        id: Holding
          .where(account_id: account_ids)
          .where(currency: family.currency)
          .select("DISTINCT ON (holdings.account_id, holdings.security_id) holdings.id")
          .order(Arel.sql("holdings.account_id, holdings.security_id, holdings.date DESC"))
      )
      .includes(:security, :account)
      .order(amount: :desc)
  end

  # Top holdings by value
  def top_holdings(limit: 5)
    current_holdings.limit(limit)
  end

  # Portfolio allocation by security type/sector (simplified for now)
  def allocation
    holdings = current_holdings.to_a
    total = holdings.sum(&:amount)

    return [] if total.zero?

    holdings.map do |holding|
      HoldingAllocation.new(
        security: holding.security,
        amount: holding.amount_money,
        weight: (holding.amount / total * 100).round(2),
        trend: holding.trend
      )
    end
  end

  # Unrealized gains across all holdings
  def unrealized_gains
    current_holdings.sum do |holding|
      trend = holding.trend
      trend ? trend.value : 0
    end
  end

  # Total contributions (all time) - returns numeric for monetize
  def total_contributions
    all_time_totals.contributions&.amount || 0
  end

  # Total dividends (all time) - returns numeric for monetize
  def total_dividends
    all_time_totals.dividends&.amount || 0
  end

  # Total interest (all time) - returns numeric for monetize
  def total_interest
    all_time_totals.interest&.amount || 0
  end

  def unrealized_gains_trend
    holdings = current_holdings.to_a
    return nil if holdings.empty?

    # Only include holdings with known cost basis in the calculation
    holdings_with_cost_basis = holdings.select(&:avg_cost)
    return nil if holdings_with_cost_basis.empty?

    current = holdings_with_cost_basis.sum(&:amount)
    previous = holdings_with_cost_basis.sum { |h| h.qty * h.avg_cost.amount }

    Trend.new(current: current, previous: previous)
  end

  # Day change across portfolio
  def day_change
    holdings = current_holdings.to_a
    changes = holdings.map(&:day_change).compact

    return nil if changes.empty?

    current = changes.sum { |t| t.current.is_a?(Money) ? t.current.amount : t.current }
    previous = changes.sum { |t| t.previous.is_a?(Money) ? t.previous.amount : t.previous }

    Trend.new(
      current: Money.new(current, family.currency),
      previous: Money.new(previous, family.currency)
    )
  end

  # Investment accounts
  def investment_accounts
    @investment_accounts ||= family.accounts.visible.where(accountable_type: %w[Investment Crypto])
  end

  private
    def all_time_totals
      @all_time_totals ||= totals(period: Period.all_time)
    end

    PeriodTotals = Data.define(:contributions, :withdrawals, :dividends, :interest, :trades_count, :currency) do
      def net_flow
        contributions - withdrawals
      end

      def total_income
        dividends + interest
      end
    end

    HoldingAllocation = Data.define(:security, :amount, :weight, :trend)

    def totals_query(trades_scope:)
      sql_hash = Digest::MD5.hexdigest(trades_scope.to_sql)

      Rails.cache.fetch([
        "investment_statement", "totals_query", family.id, sql_hash, family.entries_cache_version
      ]) { Totals.new(family, trades_scope: trades_scope).call }
    end

    def monetizable_currency
      family.currency
    end
end
