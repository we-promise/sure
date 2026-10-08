class IncomeStatement::FamilyStats
  include IncomeStatement::ScopedTransactionsQuery

  def initialize(family, interval: "month", account_ids: nil, excluding_kinds: [], date_range: nil)
    @family = family
    @interval = interval
    @account_ids = account_ids
    @excluding_kinds = excluding_kinds
    @date_range = date_range
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
      params = { interval: @interval }
      params[:excluding_kinds] = @excluding_kinds if @excluding_kinds.any?
      params.merge!(range_start: @date_range.begin, range_end: @date_range.end) if @date_range
      base_sql_params(params)
    end

    def date_range_sql
      "AND ae.date BETWEEN :range_start AND :range_end" if @date_range
    end

    # Bound as a parameter, never interpolated: the kinds come from callers.
    def excluding_kinds_sql
      "AND t.kind NOT IN (:excluding_kinds)" if @excluding_kinds.any?
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
          WHERE a.family_id = :family_id
            AND t.kind NOT IN (#{budget_excluded_kinds_sql})
            #{excluding_kinds_sql}
            #{date_range_sql}
            AND ae.excluded = false
            AND a.exclude_from_reports = false
            #{pending_providers_sql}
            #{exclude_tax_advantaged_sql}
            #{scope_to_account_ids_sql}
            #{excluding_scheduled_sql}
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
