class IncomeStatement::FamilyStats
  def initialize(family, interval: "month", account_ids: nil, include_kinds: [])
    @family = family
    @interval = interval
    @account_ids = account_ids
    @include_kinds = Array(include_kinds).map(&:to_s)
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
      params = {
        target_currency: @family.currency,
        interval: @interval,
        family_id: @family.id
      }

      ids = @family.tax_advantaged_account_ids
      params[:tax_advantaged_account_ids] = ids if ids.present?

      params
    end

    def budget_excluded_kinds_sql
      @budget_excluded_kinds_sql ||= begin
        kinds = Transaction::BUDGET_EXCLUDED_KINDS - @include_kinds
        kinds.map { |k| "'#{k}'" }.join(", ")
      end
    end

    def force_expense_kinds
      kinds = [ "loan_payment" ]
      kinds << "investment_contribution" if @include_kinds.include?("investment_contribution")
      kinds
    end

    def force_expense_kinds_sql
      force_expense_kinds.map { |k| "'#{k}'" }.join(", ")
    end

    def classification_case_sql
      "CASE WHEN t.kind IN (#{force_expense_kinds_sql}) THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END"
    end

    def amount_case_sql
      "CASE WHEN t.kind IN (#{force_expense_kinds_sql}) THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE ae.amount * COALESCE(er.rate, 1) END"
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
            date_trunc(:interval, ae.date) as period,
            #{classification_case_sql} as classification,
            SUM(#{amount_case_sql}) as total
          FROM transactions t
          JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Transaction'
          JOIN accounts a ON a.id = ae.account_id
          LEFT JOIN exchange_rates er ON (
            er.date = ae.date AND
            er.from_currency = ae.currency AND
            er.to_currency = :target_currency
          )
          WHERE a.family_id = :family_id
            AND t.kind NOT IN (#{budget_excluded_kinds_sql})
            AND ae.excluded = false
            #{pending_providers_sql}
            #{exclude_tax_advantaged_sql}
            #{scope_to_account_ids_sql}
          GROUP BY period, #{classification_case_sql}
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
