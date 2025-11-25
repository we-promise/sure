class CashflowStatement::InvestingActivities
  include Monetizable

  attr_reader :family, :period

  def initialize(family, period:)
    @family = family
    @period = period
  end

  # Inflows: Selling investments (withdrawals), dividends, capital gains
  def inflows
    @inflows ||= totals[:withdrawals]
  end

  def inflows_money
    Money.new(inflows, family.currency)
  end

  # Outflows: Buying investments (contributions)
  def outflows
    @outflows ||= totals[:contributions]
  end

  def outflows_money
    Money.new(outflows, family.currency)
  end

  def net
    inflows - outflows
  end

  def net_money
    Money.new(net, family.currency)
  end

  def trades_count
    @trades_count ||= totals[:trades_count]
  end

  def summary
    Summary.new(
      inflows: inflows_money,
      outflows: outflows_money,
      net: net_money,
      contributions: outflows_money,
      withdrawals: inflows_money,
      trades_count: trades_count
    )
  end

  # Check if there are any investment accounts
  def has_investments?
    family.accounts.visible.where(accountable_type: %w[Investment Crypto]).exists?
  end

  private
    Summary = Data.define(:inflows, :outflows, :net, :contributions, :withdrawals, :trades_count)

    def totals
      @totals ||= begin
        result = ActiveRecord::Base.connection.select_one(totals_query_sql)
        {
          contributions: result["contributions"]&.to_d || 0,
          withdrawals: result["withdrawals"]&.to_d || 0,
          trades_count: result["trades_count"]&.to_i || 0
        }
      end
    end

    def totals_query_sql
      trades_scope = family.trades
        .joins(:entry)
        .where(entries: { date: period.date_range })

      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL,
          SELECT
            COALESCE(SUM(CASE WHEN t.qty > 0 THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as contributions,
            COALESCE(SUM(CASE WHEN t.qty < 0 THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as withdrawals,
            COUNT(t.id) as trades_count
          FROM (#{trades_scope.to_sql}) t
          JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Trade'
          JOIN accounts a ON a.id = ae.account_id
          LEFT JOIN exchange_rates er ON (
            er.date = ae.date AND
            er.from_currency = ae.currency AND
            er.to_currency = :target_currency
          )
          WHERE a.family_id = :family_id
            AND a.status IN ('draft', 'active')
            AND ae.excluded = false
        SQL
        {
          family_id: family.id,
          target_currency: family.currency
        }
      ])
    end

    def monetizable_currency
      family.currency
    end
end
