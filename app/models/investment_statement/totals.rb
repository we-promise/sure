class InvestmentStatement::Totals
  def initialize(family, account_ids:, date_range:)
    raise ArgumentError, "account_ids must be enumerable" unless account_ids.respond_to?(:empty?)
    raise ArgumentError, "date_range must provide a beginning and end" unless date_range.respond_to?(:begin) && date_range.respond_to?(:end)

    @family = family
    @account_ids = account_ids
    @date_range = date_range
  end

  def call
    return empty_result if @account_ids.empty?

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
    def empty_result
      {
        contributions: 0,
        withdrawals: 0,
        dividends: 0,
        interest: 0,
        trades_count: 0
      }
    end

    def query_sql
      ActiveRecord::Base.sanitize_sql_array([
        aggregation_sql,
        sql_params
      ])
    end

    # Aggregate trades by direction (buy vs sell)
    # Buys (qty > 0) = contributions (cash going out to buy securities)
    # Sells (qty < 0) = withdrawals (cash coming in from selling securities)
    # Missing FX rates preserve InvestmentStatement's existing 1:1 fallback.
    def aggregation_sql
      <<~SQL
        SELECT
          COALESCE(SUM(CASE WHEN trades.qty > 0 THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as contributions,
          COALESCE(SUM(CASE WHEN trades.qty < 0 THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as withdrawals,
          COUNT(trades.id) as trades_count
        FROM entries
        JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'
        JOIN accounts ON accounts.id = entries.account_id
        LEFT JOIN exchange_rates er ON (
          er.date = entries.date AND
          er.from_currency = entries.currency AND
          er.to_currency = :target_currency
        )
        WHERE accounts.family_id = :family_id
          AND accounts.status IN ('draft', 'active')
          AND entries.account_id IN (:account_ids)
          AND entries.date BETWEEN :start_date AND :end_date
          AND entries.excluded = false
      SQL
    end

    def sql_params
      {
        family_id: @family.id,
        target_currency: @family.currency,
        account_ids: @account_ids,
        start_date: @date_range.begin,
        end_date: @date_range.end
      }
    end
end
