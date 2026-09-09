class IncomeStatement::FamilyStats
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
        classification: row["classification"],
        median: row["median"],
        avg: row["avg"]
      )
    end
  end

  private
    StatRow = Data.define(:classification, :median, :avg)

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
            date_trunc(:interval, ae.date) as period,
            #{classification_sql("t")} as classification,
            SUM(#{converted_amount_sql("t")}) as total
          FROM transactions t
          #{entries_join_sql("t")}
          #{accounts_join_sql}
          #{exchange_rates_join_sql}
          WHERE a.family_id = :family_id
            AND t.kind NOT IN (#{budget_excluded_kinds_sql})
            AND ae.excluded = false
            AND a.exclude_from_reports = false
            #{pending_providers_sql}
            #{exclude_tax_advantaged_sql}
            #{scope_to_account_ids_sql}
          GROUP BY period, #{classification_sql("t")}
        )
        SELECT
          classification,
          ABS(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total)) as median,
          ABS(AVG(total)) as avg
        FROM period_totals
        GROUP BY classification;
      SQL
    end
end
