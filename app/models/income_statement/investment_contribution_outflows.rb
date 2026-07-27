class IncomeStatement::InvestmentContributionOutflows
  def initialize(family, date_range:, included_account_ids: nil)
    @family = family
    @date_range = date_range
    @included_account_ids = included_account_ids
  end

  def call
    return Money.new(0, @family.currency) if @included_account_ids&.empty?

    total = ActiveRecord::Base.connection.select_value(sanitized_query_sql)
    Money.new(total || 0, @family.currency)
  end

  private
    def sanitized_query_sql
      ActiveRecord::Base.sanitize_sql_array([ query_sql, sql_params ])
    end

    def query_sql
      <<~SQL
        SELECT COALESCE(SUM(ABS(ae.amount * COALESCE(er.rate, 1))), 0)
        FROM transactions t
        JOIN transfers tr ON tr.outflow_transaction_id = t.id
        JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = ae.account_id
        LEFT JOIN exchange_rates er ON (
          er.date = ae.date AND
          er.from_currency = ae.currency AND
          er.to_currency = :target_currency
        )
        WHERE t.kind = 'investment_contribution'
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          AND ae.date BETWEEN :start_date AND :end_date
          AND NOT (#{Transaction.pending_providers_sql("t")})
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
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
end
