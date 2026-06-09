class Holding::CalculatedAvgCosts
  def initialize(holdings)
    @holdings = Array(holdings).select(&:needs_calculated_avg_cost?)
  end

  def apply!
    return if @holdings.empty?

    averages = fetch_averages

    @holdings.each do |holding|
      holding.preload_calculated_avg_cost!(averages[holding_key(holding)])
    end
  end

  private
    def fetch_averages
      values_clause = @holdings.map do |holding|
        ActiveRecord::Base.sanitize_sql_array([
          "(?::uuid, ?::uuid, ?::date, ?, ?)",
          holding.account_id,
          holding.security_id,
          holding.date,
          holding.account.currency,
          holding.currency
        ])
      end.join(", ")

      sql = <<~SQL
        WITH holding_specs(account_id, security_id, as_of_date, target_currency, holding_currency) AS (
          VALUES #{values_clause}
        )
        SELECT
          holding_specs.account_id,
          holding_specs.security_id,
          holding_specs.as_of_date,
          holding_specs.holding_currency,
          SUM(trades.price * trades.qty * COALESCE(exchange_rates.rate, 1)) AS total_cost,
          SUM(trades.qty) AS total_qty
        FROM holding_specs
        JOIN trades ON trades.security_id = holding_specs.security_id
        JOIN entries ON entries.entryable_id = trades.id
          AND entries.entryable_type = 'Trade'
          AND entries.account_id = holding_specs.account_id
        LEFT JOIN exchange_rates ON (
          exchange_rates.date = entries.date
          AND exchange_rates.from_currency = trades.currency
          AND exchange_rates.to_currency = holding_specs.target_currency
        )
        WHERE trades.qty > 0
          AND entries.date <= holding_specs.as_of_date
        GROUP BY
          holding_specs.account_id,
          holding_specs.security_id,
          holding_specs.as_of_date,
          holding_specs.holding_currency
        HAVING SUM(trades.qty) > 0
      SQL

      ActiveRecord::Base.connection.select_all(sql).each_with_object({}) do |row, memo|
        memo[holding_key_from_row(row)] = {
          total_cost: row["total_cost"].to_d,
          total_qty: row["total_qty"].to_d,
          currency: row["holding_currency"]
        }
      end
    end

    def holding_key(holding)
      [ holding.account_id, holding.security_id, holding.date, holding.currency ]
    end

    def holding_key_from_row(row)
      [ row["account_id"], row["security_id"], row["as_of_date"].to_date, row["holding_currency"] ]
    end
end
