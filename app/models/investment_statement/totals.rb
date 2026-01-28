class InvestmentStatement::Totals
  def initialize(family, trades_scope:)
    @family = family
    @trades_scope = trades_scope
  end

  def call
    result = ActiveRecord::Base.connection.select_one(query_sql)

    {
      contributions: result["contributions"]&.to_d || 0,
      withdrawals: result["withdrawals"]&.to_d || 0,
      dividends: 0, # Dividends come through as transactions, not trades
      interest: 0,  # Interest comes through as transactions, not trades
      trades_count: result["trades_count"]&.to_i || 0
    }
  end

  private
    def query_sql
      ActiveRecord::Base.sanitize_sql_array([
        aggregation_sql,
        sql_params
      ])
    end

    # Aggregate trades by direction (buy vs sell)
    # Buys (qty > 0) = contributions (cash going out to buy securities)
    # Sells (qty < 0) = withdrawals (cash coming in from selling securities)
    def aggregation_sql
      <<~SQL
        SELECT
          COALESCE(SUM(CASE WHEN t.qty > 0 THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as contributions,
          COALESCE(SUM(CASE WHEN t.qty < 0 THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as withdrawals,
          COUNT(t.id) as trades_count
        FROM (#{@trades_scope.to_sql}) t
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
    end

    def sql_params
      {
        family_id: @family.id,
        target_currency: @family.currency
      }
    end
end
