# Per-day expense totals (in the family's currency) for a period, used by the
# dashboard's cumulative spending chart. Follows the same scoping rules as
# IncomeStatement::Totals (visible, posted, budget-included transactions in
# report-included accounts, converted at the day's exchange rate) so the
# series always agrees with the totals shown elsewhere on the dashboard.
class IncomeStatement::DailyExpenseTotals
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
            CASE WHEN at.kind IN ('investment_contribution', 'loan_payment') THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END as classification,
            ABS(SUM(CASE WHEN at.kind IN ('investment_contribution', 'loan_payment') THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE ae.amount * COALESCE(er.rate, 1) END)) as total
          FROM (#{@transactions_scope.to_sql}) at
          JOIN entries ae ON ae.entryable_id = at.id AND ae.entryable_type = 'Transaction'
          JOIN accounts a ON a.id = ae.account_id
          LEFT JOIN exchange_rates er ON (
            er.date = ae.date AND
            er.from_currency = ae.currency AND
            er.to_currency = :target_currency
          )
          WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
            AND (
              at.investment_activity_label IS NULL
              OR at.investment_activity_label NOT IN ('Transfer', 'Sweep In', 'Sweep Out', 'Exchange')
            )
            AND ae.excluded = false
            AND a.family_id = :family_id
            AND a.status IN ('draft', 'active')
            AND a.exclude_from_reports = false
            #{exclude_tax_advantaged_sql}
            #{include_finance_accounts_sql}
          GROUP BY ae.date, CASE WHEN at.kind IN ('investment_contribution', 'loan_payment') THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END
        ) daily
        WHERE classification = 'expense'
        ORDER BY day
      SQL
    end

    def sql_params
      params = {
        target_currency: @family.currency,
        family_id: @family.id,
        start_date: @date_range.begin,
        end_date: @date_range.end
      }

      ids = @family.tax_advantaged_account_ids
      params[:tax_advantaged_account_ids] = ids if ids.present?

      params[:included_account_ids] = @included_account_ids if @included_account_ids

      params
    end

    def exclude_tax_advantaged_sql
      ids = @family.tax_advantaged_account_ids
      return "" if ids.empty?
      "AND a.id NOT IN (:tax_advantaged_account_ids)"
    end

    def include_finance_accounts_sql
      return "" if @included_account_ids.nil?
      "AND a.id IN (:included_account_ids)"
    end

    def budget_excluded_kinds_sql
      @budget_excluded_kinds_sql ||= Transaction::BUDGET_EXCLUDED_KINDS.map { |k| "'#{k}'" }.join(", ")
    end

    def validate_date_range!
      unless @date_range.is_a?(Range)
        raise ArgumentError, "date_range must be a Range, got #{@date_range.class}"
      end

      unless @date_range.begin.respond_to?(:to_date) && @date_range.end.respond_to?(:to_date)
        raise ArgumentError, "date_range must contain date-like objects"
      end
    end
end
