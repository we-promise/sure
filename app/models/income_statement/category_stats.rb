class IncomeStatement::CategoryStats
  include IncomeStatement::ScopedTransactionsQuery

  def initialize(family, interval: "month", account_ids: nil)
    @family = family
    @interval = interval
    @account_ids = account_ids
  end

  def call
    return [] if @account_ids&.empty?

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
      base_sql_params(interval: @interval)
    end

    def query_sql
      <<~SQL
        WITH period_totals AS (
          SELECT
            c.id as category_id,
            date_trunc(:interval, ae.date) as period,
            #{classification_sql("t")} as classification,
            SUM(#{converted_amount_sql("t")}) as total
          FROM transactions t
          #{entries_join_sql("t")}
          #{accounts_join_sql}
          LEFT JOIN categories c ON c.id = t.category_id
          #{exchange_rates_join_sql}
          WHERE a.family_id = :family_id
            AND t.kind NOT IN (#{budget_excluded_kinds_sql})
            AND ae.excluded = false
            AND a.exclude_from_reports = false
            #{pending_providers_sql}
            #{exclude_tax_advantaged_sql}
            #{scope_to_account_ids_sql}
          GROUP BY c.id, period, #{classification_sql("t")}
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
