# Income/expense totals for a date range, bucketed by calendar month in one
# query. Applies the same scoping and amount conversion as
# IncomeStatement::Totals, so each month's bucket matches what `totals_for`
# reports for that month alone. Used by multi-month charts (e.g. the
# dashboard's money flow bars) to avoid one totals query per month.
class IncomeStatement::MonthlyTotals
  include IncomeStatement::ScopedTransactionsQuery

  def initialize(family, transactions_scope:, date_range:, included_account_ids: nil)
    @family = family
    @transactions_scope = transactions_scope
    @date_range = date_range
    @included_account_ids = included_account_ids

    validate_date_range!
  end

  def call
    # No finance accounts means no transactions to report
    return [] if @included_account_ids&.empty?

    ActiveRecord::Base.connection.select_all(query_sql).map do |row|
      MonthlyRow.new(
        month: row["month"].to_date,
        classification: row["classification"],
        total: row["total"],
        transactions_count: row["transactions_count"]
      )
    end
  end

  MonthlyRow = Data.define(:month, :classification, :total, :transactions_count)

  private
    def query_sql
      ActiveRecord::Base.sanitize_sql_array([ monthly_query_sql, sql_params ])
    end

    # Mirrors Totals#transactions_subquery_sql, adding the entry month to the
    # grouping. Category grouping is collapsed afterwards since callers only
    # need per-classification sums, but it is kept here so ABS() applies per
    # category exactly as it does in Totals.
    def monthly_query_sql
      <<~SQL
        SELECT
          month,
          classification,
          SUM(total) as total,
          SUM(entry_count) as transactions_count
        FROM (
          SELECT
            DATE_TRUNC('month', ae.date)::date as month,
            c.id as category_id,
            #{classification_sql("at")} as classification,
            ABS(SUM(#{converted_amount_sql("at")})) as total,
            COUNT(ae.id) as entry_count
          FROM (#{@transactions_scope.to_sql}) at
          #{entries_join_sql("at")}
          #{accounts_join_sql}
          LEFT JOIN categories c ON c.id = at.category_id
          #{exchange_rates_join_sql}
          WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
            #{investment_activity_label_sql("at")}
            AND ae.excluded = false
            AND a.family_id = :family_id
            AND a.status IN ('draft', 'active')
            AND a.exclude_from_reports = false
            #{exclude_tax_advantaged_sql}
            #{include_finance_accounts_sql}
          GROUP BY DATE_TRUNC('month', ae.date)::date, c.id, c.parent_id, #{classification_sql("at")}
        ) per_category
        GROUP BY month, classification;
      SQL
    end

    def sql_params
      params = base_sql_params(start_date: @date_range.begin, end_date: @date_range.end)
      params[:included_account_ids] = @included_account_ids if @included_account_ids
      params
    end
end
