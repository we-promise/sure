require "digest/md5"

class InvestmentStatement
  include Monetizable

  monetize :total_contributions, :total_dividends, :total_interest, :unrealized_gains

  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user || Current.user
  end

  # Get totals for a specific period
  def totals(period: Period.current_month)
    trades_in_period = family.trades
      .joins(:entry)
      .where(entries: { date: period.date_range, account_id: investment_account_ids })

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
    investment_accounts.sum { |a| convert_to_family_currency(a.balance, a.currency) }
  end

  def portfolio_value_money
    Money.new(portfolio_value, family.currency)
  end

  # Total cash in investment accounts
  def cash_balance
    investment_accounts.sum { |a| convert_to_family_currency(a.cash_balance, a.currency) }
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

  # All current holdings across investment accounts. Holdings are returned in
  # their native currency; callers that aggregate across accounts must convert
  # to family currency via convert_to_family_currency.
  def current_holdings
    return Holding.none unless investment_accounts.any?

    # Get the latest holding for each security per account
    Holding
      .where(account_id: investment_account_ids)
      .where.not(qty: 0)
      .where(
        id: Holding
          .where(account_id: investment_account_ids)
          .select("DISTINCT ON (holdings.account_id, holdings.security_id) holdings.id")
          .order(Arel.sql("holdings.account_id, holdings.security_id, holdings.date DESC"))
      )
      .includes(:security, :account)
  end

  # Top holdings by family-currency value
  def top_holdings(limit: 5)
    current_holdings
      .to_a
      .sort_by { |h| -convert_to_family_currency(h.amount, h.currency) }
      .first(limit)
  end

  # Portfolio allocation by security. Weights and amounts are computed in the
  # family's currency so cross-currency holdings compare correctly.
  def allocation
    converted = current_holdings.to_a.map do |holding|
      [ holding, convert_to_family_currency(holding.amount, holding.currency) ]
    end

    total = converted.sum { |_, value| value }
    return [] if total.zero?

    converted
      .sort_by { |_, value| -value }
      .map do |holding, value|
        HoldingAllocation.new(
          security: holding.security,
          amount: Money.new(value, family.currency),
          weight: (value / total * 100).round(2),
          trend: holding.trend
        )
      end
  end

  # Unrealized gains across all holdings, summed in family currency
  def unrealized_gains
    current_holdings.sum do |holding|
      trend = holding.trend
      trend ? convert_to_family_currency(trend.value, holding.currency) : 0
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

    current = holdings_with_cost_basis.sum do |h|
      convert_to_family_currency(h.amount, h.currency)
    end
    previous = holdings_with_cost_basis.sum do |h|
      convert_to_family_currency(h.qty * h.avg_cost.amount, h.currency)
    end

    Trend.new(
      current: Money.new(current, family.currency),
      previous: Money.new(previous, family.currency)
    )
  end

  # Day change across portfolio, summed in family currency
  def day_change
    changes = current_holdings.to_a.filter_map do |h|
      t = h.day_change
      next nil unless t
      curr = t.current.is_a?(Money) ? t.current.amount : t.current
      prev = t.previous.is_a?(Money) ? t.previous.amount : t.previous
      [
        convert_to_family_currency(curr, h.currency),
        convert_to_family_currency(prev, h.currency)
      ]
    end

    return nil if changes.empty?

    Trend.new(
      current: Money.new(changes.sum { |c, _| c }, family.currency),
      previous: Money.new(changes.sum { |_, p| p }, family.currency)
    )
  end

  # Investment accounts
  def investment_accounts
    @investment_accounts ||= begin
      scope = family.accounts.visible.where(accountable_type: %w[Investment Crypto])
      scope = scope.included_in_finances_for(user) if user
      scope
    end
  end

  private
    # Today's rates for every currency present on the family's investment
    # accounts and their holdings. Mirrors BalanceSheet::AccountTotals#exchange_rates.
    def exchange_rates
      @exchange_rates ||= begin
        account_currencies = investment_accounts.map(&:currency)
        holding_currencies = Holding.where(account_id: investment_account_ids).distinct.pluck(:currency)
        foreign = (account_currencies + holding_currencies)
                    .compact
                    .uniq
                    .reject { |c| c == family.currency }
        ExchangeRate.rates_for(foreign, to: family.currency, date: Date.current)
      end
    end

    def convert_to_family_currency(amount, from_currency)
      return amount if amount.nil? || from_currency == family.currency
      rate = exchange_rates[from_currency] || 1
      amount * rate
    end

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

    def investment_account_ids
      @investment_account_ids ||= investment_accounts.pluck(:id)
    end

    def totals_query(trades_scope:)
      sql_hash = Digest::MD5.hexdigest(trades_scope.to_sql)

      Rails.cache.fetch([
        "investment_statement", "totals_query", family.id, user&.id, sql_hash, family.entries_cache_version
      ]) { Totals.new(family, trades_scope: trades_scope).call }
    end

    def monetizable_currency
      family.currency
    end
end
