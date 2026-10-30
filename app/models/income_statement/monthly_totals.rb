# Income/expense totals per calendar month across a date range, in one
# query. Powers the dashboard's money flow bar chart, which previously ran
# IncomeStatement::Totals once per month (an N+1 on the dashboard).
#
# Mirrors IncomeStatement::Totals' transactions subquery (same scoping via
# IncomeStatement::ScopedTransactionsQuery) but groups by entry month and
# classification instead of category. Within a classification every row's
# converted amount has the same sign, so ABS(SUM(...)) per month equals the
# sum of Totals' per-category ABS(SUM(...)) rows for that month.
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
      MonthlyTotalRow.new(
        month: row["month"].to_date,
        classification: row["classification"],
        total: row["total"],
        transactions_count: row["transactions_count"]
      )
    end
  end

  private
    MonthlyTotalRow = Data.define(:month, :classification, :total, :transactions_count)

    def query_sql
      ActiveRecord::Base.sanitize_sql_array([ query_sql_body, sql_params ])
    end

    # The month and classification expressions are repeated in the GROUP BY
    # (rather than referenced by alias) because only some databases accept
    # aliases there.
    def query_sql_body
      <<~SQL
        SELECT
          DATE_TRUNC('month', ae.date)::date as month,
          #{classification_sql("at")} as classification,
          ABS(SUM(#{converted_amount_sql("at")})) as total,
          COUNT(ae.id) as transactions_count
        FROM (#{@transactions_scope.to_sql}) at
        #{entries_join_sql("at")}
        #{accounts_join_sql}
        #{exchange_rates_join_sql}
        WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
          #{investment_activity_label_sql("at")}
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
        GROUP BY DATE_TRUNC('month', ae.date), #{classification_sql("at")}
        ORDER BY month
      SQL
    end

    def sql_params
      params = base_sql_params(start_date: @date_range.begin, end_date: @date_range.end)
      params[:included_account_ids] = @included_account_ids if @included_account_ids
      params
    end
end
