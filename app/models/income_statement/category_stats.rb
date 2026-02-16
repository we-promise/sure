class IncomeStatement::CategoryStats
  def initialize(family, interval: "month")
    @family = family
    @interval = interval
  end

  def call
    ActiveRecord::Base.connection.select_all(sanitized_query_sql).map do |row|
      StatRow.new(
        category_id: row["category_id"],
        classification: row["classification"],
        median: row["median"],
        avg: row["avg"]
      )
    end
  end

  private
    StatRow = Data.define(:category_id, :classification, :median, :avg)

    def sanitized_query_sql
      ActiveRecord::Base.sanitize_sql_array([
        query_sql,
        sql_params
      ])
    end

    def sql_params
      params = {
        target_currency: @family.currency,
        interval: @interval,
        family_id: @family.id
      }

      ids = @family.tax_advantaged_account_ids
      params[:tax_advantaged_account_ids] = ids if ids.present?

      params
    end

    def budget_excluded_kinds_sql
      @budget_excluded_kinds_sql ||= Transaction::BUDGET_EXCLUDED_KINDS.map { |k| "'#{k}'" }.join(", ")
    end

    def exclude_tax_advantaged_sql
      ids = @family.tax_advantaged_account_ids
      return "" if ids.empty?
      "AND a.id NOT IN (:tax_advantaged_account_ids)"
    end

    def query_sql
      <<~SQL
        WITH period_totals AS (
          SELECT
            c.id as category_id,
            date_trunc(:interval, ae.date) as period,
            CASE WHEN t.kind = 'investment_contribution' THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END as classification,
            SUM(CASE WHEN t.kind = 'investment_contribution' THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE ae.amount * COALESCE(er.rate, 1) END) as total
          FROM transactions t
          JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Transaction'
          JOIN accounts a ON a.id = ae.account_id
          LEFT JOIN categories c ON c.id = t.category_id
          LEFT JOIN exchange_rates er ON (
            er.date = ae.date AND
            er.from_currency = ae.currency AND
            er.to_currency = :target_currency
          )
          WHERE a.family_id = :family_id
            AND t.kind NOT IN (#{budget_excluded_kinds_sql})
            AND ae.excluded = false
            AND (t.extra -> 'simplefin' ->> 'pending')::boolean IS DISTINCT FROM true
            AND (t.extra -> 'plaid' ->> 'pending')::boolean IS DISTINCT FROM true
            #{exclude_tax_advantaged_sql}
          GROUP BY c.id, period, CASE WHEN t.kind = 'investment_contribution' THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END
        )
        SELECT
          category_id,
          classification,
          ABS(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total)) as median,
          ABS(AVG(total)) as avg
        FROM period_totals
        GROUP BY category_id, classification;
      SQL
    end
end
