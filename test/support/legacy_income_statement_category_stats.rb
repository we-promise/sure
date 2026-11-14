# Verbatim copy of IncomeStatement::CategoryStats as it existed on main before the
# IncomeStatement::ScopedTransactionsQuery refactor (base commit 947fe832),
# renamed so both implementations can run side by side.
# ScopedTransactionsQueryEquivalenceTest runs each refactored class and its
# legacy counterpart over the same data and option matrix and asserts
# identical results. Delete once the refactor is merged and trusted.
class LegacyIncomeStatementCategoryStats
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
      params = {
        target_currency: @family.currency,
        interval: @interval,
        family_id: @family.id,
        today: Date.current
      }

      ids = @family.tax_advantaged_account_ids
      params[:tax_advantaged_account_ids] = ids if ids.present?

      params
    end

    def budget_excluded_kinds_sql
      @budget_excluded_kinds_sql ||= Transaction::BUDGET_EXCLUDED_KINDS.map { |k| "'#{k}'" }.join(", ")
    end

    def pending_providers_sql
      Transaction.pending_providers_sql("t")
    end

    def exclude_tax_advantaged_sql
      ids = @family.tax_advantaged_account_ids
      return "" if ids.empty?
      "AND a.id NOT IN (:tax_advantaged_account_ids)"
    end

    def scope_to_account_ids_sql
      return "" if @account_ids.nil?
      ActiveRecord::Base.sanitize_sql([ "AND a.id IN (?)", @account_ids ])
    end

    def query_sql
      <<~SQL
        WITH period_totals AS (
          SELECT
            c.id as category_id,
            date_trunc(:interval, ae.date) as period,
            CASE WHEN t.kind IN ('investment_contribution', 'loan_payment') THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END as classification,
            SUM(CASE WHEN t.kind IN ('investment_contribution', 'loan_payment') THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE ae.amount * COALESCE(er.rate, 1) END) as total
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
            AND a.exclude_from_reports = false
            #{pending_providers_sql}
            #{exclude_tax_advantaged_sql}
            #{scope_to_account_ids_sql}
          GROUP BY c.id, period, CASE WHEN t.kind IN ('investment_contribution', 'loan_payment') THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END
        )
        -- Mirrors CategoryStats' zero-filled average, added after the refactor.
        , bounds AS (
          SELECT COALESCE(MAX(period), date_trunc(:interval, CAST(:today AS date)) - CAST('1 ' || :interval AS interval)) AS last_p
          FROM period_totals WHERE period < date_trunc(:interval, CAST(:today AS date))
        )
        -- end_p: the category's latest period with spending, or the latest past period in scope.
        , windowed AS (
          SELECT period_totals.*, GREATEST(MAX(period) OVER (PARTITION BY category_id, classification), (SELECT last_p FROM bounds)) AS end_p
          FROM period_totals
        )
        SELECT
          category_id,
          classification,
          ABS(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total)) as median,
          ABS(COALESCE(SUM(total) FILTER (WHERE period > end_p - CAST('12 ' || :interval AS interval)), 0) / (
            SELECT COUNT(*) FROM generate_series(GREATEST(MIN(period), MAX(end_p) - CAST('11 ' || :interval AS interval)),
              MAX(end_p), CAST('1 ' || :interval AS interval))
          )) as avg
        FROM windowed
        GROUP BY category_id, classification;
      SQL
    end
end
