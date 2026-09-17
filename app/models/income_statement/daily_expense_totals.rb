# Per-day expense totals (in the family's currency) for a period, used by the
# dashboard's cumulative spending chart. Shares its scoping SQL with the
# other IncomeStatement query classes via
# IncomeStatement::ScopedTransactionsQuery (visible, posted, budget-included
# transactions in report-included accounts, converted at the day's exchange
# rate) so the series always agrees with the totals shown elsewhere on the
# dashboard.
class IncomeStatement::DailyExpenseTotals
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
      DailyTotal.new(date: row["day"].to_date, total: row["total"])
    end
  end

  private
    DailyTotal = Data.define(:date, :total)

    def query_sql
      ActiveRecord::Base.sanitize_sql_array([ query_sql_body, sql_params ])
    end

    # Mirrors IncomeStatement::Totals' transactions subquery, but groups by
    # entry date instead of category and keeps only the expense rows. The
    # classification CASE is repeated in the GROUP BY (rather than referenced
    # by alias) because only some databases accept aliases there.
    def query_sql_body
      <<~SQL
        SELECT day, total FROM (
          SELECT
            ae.date as day,
            #{classification_sql("at")} as classification,
            ABS(SUM(#{converted_amount_sql("at")})) as total
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
          GROUP BY ae.date, #{classification_sql("at")}
        ) daily
        WHERE classification = 'expense'
        ORDER BY day
      SQL
    end

    def sql_params
      params = base_sql_params(start_date: @date_range.begin, end_date: @date_range.end)
      params[:included_account_ids] = @included_account_ids if @included_account_ids
      params
    end
end
