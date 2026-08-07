# Income/expense totals bucketed by calendar month in a single query.
#
# `IncomeStatement::Totals` answers "what are the category totals for one
# period?". Callers that need a run of months (the dashboard money flow
# widget) were invoking it once per month, issuing that many near-identical
# multi-join aggregates per request. Grouping by month instead makes a
# contiguous span cost one round trip.
#
# Grouping by (month, classification) rather than Totals' (month, category,
# classification) does not change the figures: every row within a
# classification contributes the same sign — income rows are negative
# amounts, expense rows are forced positive — so ABS(SUM(...)) over a whole
# month bucket equals the sum of the per-category ABS(SUM(...)) values that
# Totals produces. Categories are therefore left unjoined here.
class IncomeStatement::MonthlyTotals
  MonthRow = Data.define(:month, :classification, :total, :transactions_count)

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
      MonthRow.new(
        month: normalize_month(row["month"]),
        classification: row["classification"],
        total: row["total"],
        transactions_count: row["transactions_count"]
      )
    end
  end

  private
    def normalize_month(value)
      value.is_a?(String) ? Date.parse(value) : value.to_date
    end

    def query_sql
      ActiveRecord::Base.sanitize_sql_array([ monthly_query_sql, sql_params ])
    end

    # Mirrors IncomeStatement::Totals#transactions_subquery_sql filter-for-filter;
    # only the SELECT/GROUP BY differ. Trades are excluded from income/expense
    # totals there too, so there is no trades arm to union in here.
    def monthly_query_sql
      <<~SQL
        SELECT
          DATE_TRUNC('month', ae.date)::date as month,
          CASE WHEN at.kind IN ('investment_contribution', 'loan_payment') THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END as classification,
          ABS(SUM(CASE WHEN at.kind IN ('investment_contribution', 'loan_payment') THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE ae.amount * COALESCE(er.rate, 1) END)) as total,
          COUNT(ae.id) as transactions_count
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
            OR at.investment_activity_label NOT IN (#{internal_movement_labels_sql})
          )
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
        GROUP BY
          DATE_TRUNC('month', ae.date)::date,
          CASE WHEN at.kind IN ('investment_contribution', 'loan_payment') THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END;
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
      @budget_excluded_kinds_sql ||= Transaction::BUDGET_EXCLUDED_KINDS.map { |kind| ActiveRecord::Base.connection.quote(kind) }.join(", ")
    end

    def internal_movement_labels_sql
      @internal_movement_labels_sql ||= Transaction::INTERNAL_MOVEMENT_LABELS.map { |label| ActiveRecord::Base.connection.quote(label) }.join(", ")
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
