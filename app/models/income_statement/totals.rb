class IncomeStatement::Totals
  def initialize(family, transactions_scope:, date_range:, include_trades: true)
    @family = family
    @transactions_scope = transactions_scope
    @date_range = date_range
    @include_trades = include_trades

    validate_date_range!
  end

  def call
    ActiveRecord::Base.connection.select_all(query_sql).map do |row|
      TotalsRow.new(
        parent_category_id: row["parent_category_id"],
        category_id: row["category_id"],
        classification: row["classification"],
        total: row["total"],
        transactions_count: row["transactions_count"],
        is_uncategorized_investment: row["is_uncategorized_investment"]
      )
    end
  end

  private
    TotalsRow = Data.define(:parent_category_id, :category_id, :classification, :total, :transactions_count, :is_uncategorized_investment)

    def query_sql
      ActiveRecord::Base.sanitize_sql_array([
        @include_trades ? combined_query_sql : transactions_only_query_sql,
        sql_params
      ])
    end

    # Combined query that includes both transactions and trades
    def combined_query_sql
      <<~SQL
        SELECT
          category_id,
          parent_category_id,
          classification,
          is_uncategorized_investment,
          SUM(total) as total,
          SUM(entry_count) as transactions_count
        FROM (
          #{transactions_subquery_sql}
          UNION ALL
          #{trades_subquery_sql}
        ) combined
        GROUP BY category_id, parent_category_id, classification, is_uncategorized_investment;
      SQL
    end

    # Original transactions-only query (for backwards compatibility)
    def transactions_only_query_sql
      <<~SQL
        SELECT
          c.id as category_id,
          c.parent_id as parent_category_id,
          CASE WHEN at.kind = 'investment_contribution' THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END as classification,
          ABS(SUM(CASE WHEN at.kind = 'investment_contribution' THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE ae.amount * COALESCE(er.rate, 1) END)) as total,
          COUNT(ae.id) as transactions_count,
          false as is_uncategorized_investment
        FROM (#{@transactions_scope.to_sql}) at
        JOIN entries ae ON ae.entryable_id = at.id AND ae.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = ae.account_id
        LEFT JOIN categories c ON c.id = at.category_id
        LEFT JOIN exchange_rates er ON (
          er.date = ae.date AND
          er.from_currency = ae.currency AND
          er.to_currency = :target_currency
        )
        WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          #{exclude_tax_advantaged_sql}
        GROUP BY c.id, c.parent_id, CASE WHEN at.kind = 'investment_contribution' THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END;
      SQL
    end

    def transactions_subquery_sql
      <<~SQL
        SELECT
          c.id as category_id,
          c.parent_id as parent_category_id,
          CASE WHEN at.kind = 'investment_contribution' THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END as classification,
          ABS(SUM(CASE WHEN at.kind = 'investment_contribution' THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE ae.amount * COALESCE(er.rate, 1) END)) as total,
          COUNT(ae.id) as entry_count,
          false as is_uncategorized_investment
        FROM (#{@transactions_scope.to_sql}) at
        JOIN entries ae ON ae.entryable_id = at.id AND ae.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = ae.account_id
        LEFT JOIN categories c ON c.id = at.category_id
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
          #{exclude_tax_advantaged_sql}
        GROUP BY c.id, c.parent_id, CASE WHEN at.kind = 'investment_contribution' THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END
      SQL
    end

    def trades_subquery_sql
      # Trades are completely excluded from income/expense budgets
      # Rationale: Trades represent portfolio rebalancing, not cash flow
      # Example: Selling $10k AAPL to buy MSFT = no net worth change, not an expense
      # Contributions/withdrawals are tracked separately as Transactions with activity labels
      <<~SQL
        SELECT NULL as category_id, NULL as parent_category_id, NULL as classification,
               NULL as total, NULL as entry_count, NULL as is_uncategorized_investment
        WHERE false
      SQL
    end

    def sql_params
      params = {
        target_currency: @family.currency,
        family_id: @family.id,
        start_date: @date_range.begin,
        end_date: @date_range.end
      }

      # Add tax-advantaged account IDs if any exist
      ids = @family.tax_advantaged_account_ids
      params[:tax_advantaged_account_ids] = ids if ids.present?

      params
    end

    # Returns SQL clause to exclude tax-advantaged accounts from budget calculations.
    # Tax-advantaged accounts (401k, IRA, HSA, etc.) are retirement savings, not daily expenses.
    def exclude_tax_advantaged_sql
      ids = @family.tax_advantaged_account_ids
      return "" if ids.empty?
      "AND a.id NOT IN (:tax_advantaged_account_ids)"
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
