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
          WHERE a.family_id = :family_id
            AND t.kind NOT IN (#{budget_excluded_kinds_sql})
            AND ae.excluded = false
            AND a.exclude_from_reports = false
            #{pending_providers_sql}
            #{exclude_tax_advantaged_sql}
            #{scope_to_account_ids_sql}
            #{excluding_scheduled_sql}
          GROUP BY c.id, period, #{classification_sql("t")}
        ),
        bounds AS (
          SELECT COALESCE(MAX(period), date_trunc(:interval, CAST(:today AS date)) - CAST('1 ' || :interval AS interval)) AS last_p
          FROM period_totals WHERE period < date_trunc(:interval, CAST(:today AS date)) AND total IS NOT NULL
        )
        -- A NULL total is a period whose only rows have no exchange rate (see
        -- converted_amount_sql). It has no measurable spending, so it neither
        -- starts, ends nor counts toward a category's run of periods.
        -- start_p: the category's first period with measurable spending.
        -- end_p: its latest one, or the latest past period in scope.
        , windowed AS (
          SELECT period_totals.*,
            MIN(period) FILTER (WHERE total IS NOT NULL) OVER (PARTITION BY category_id, classification) AS start_p,
            GREATEST(MAX(period) FILTER (WHERE total IS NOT NULL) OVER (PARTITION BY category_id, classification), (SELECT last_p FROM bounds)) AS end_p
          FROM period_totals
        )
        SELECT
          category_id,
          classification,
          ABS(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total)) as median,
          -- Average over every period from start_p to end_p, at most 12
          -- periods, so periods without spending count as zero. The unfinished
          -- current period counts only once it has spending. Periods with
          -- nothing convertible are left out of the count, and a category with
          -- no measurable period has no average.
          CASE WHEN MAX(start_p) IS NOT NULL THEN
            ABS(COALESCE(SUM(total) FILTER (WHERE period > end_p - CAST('12 ' || :interval AS interval)), 0) / NULLIF((
              SELECT COUNT(*) FROM generate_series(GREATEST(MAX(start_p), MAX(end_p) - CAST('11 ' || :interval AS interval)),
                MAX(end_p), CAST('1 ' || :interval AS interval))
            ) - COUNT(*) FILTER (
              WHERE total IS NULL AND period > start_p AND period <= end_p
                AND period > end_p - CAST('12 ' || :interval AS interval)
            ), 0))
          END as avg
        FROM windowed
        GROUP BY category_id, classification;
      SQL
    end
end
