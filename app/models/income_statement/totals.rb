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
        transactions_count: row["transactions_count"]
      )
    end
  end

  private
    TotalsRow = Data.define(:parent_category_id, :category_id, :classification, :total, :transactions_count)

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
          SUM(total) as total,
          SUM(entry_count) as transactions_count
        FROM (
          #{transactions_subquery_sql}
          UNION ALL
          #{trades_subquery_sql}
        ) combined
        GROUP BY category_id, parent_category_id, classification;
      SQL
    end

    # Original transactions-only query (for backwards compatibility)
    def transactions_only_query_sql
      <<~SQL
        SELECT
          c.id as category_id,
          c.parent_id as parent_category_id,
          CASE WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END as classification,
          ABS(SUM(ae.amount * COALESCE(er.rate, 1))) as total,
          COUNT(ae.id) as transactions_count
        FROM (#{@transactions_scope.to_sql}) at
        JOIN entries ae ON ae.entryable_id = at.id AND ae.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = ae.account_id
        LEFT JOIN categories c ON c.id = at.category_id
        LEFT JOIN exchange_rates er ON (
          er.date = ae.date AND
          er.from_currency = ae.currency AND
          er.to_currency = :target_currency
        )
        WHERE at.kind NOT IN ('funds_movement', 'one_time', 'cc_payment')
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
        GROUP BY c.id, c.parent_id, CASE WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END;
      SQL
    end

    def transactions_subquery_sql
      <<~SQL
        SELECT
          c.id as category_id,
          c.parent_id as parent_category_id,
          CASE WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END as classification,
          ABS(SUM(ae.amount * COALESCE(er.rate, 1))) as total,
          COUNT(ae.id) as entry_count
        FROM (#{@transactions_scope.to_sql}) at
        JOIN entries ae ON ae.entryable_id = at.id AND ae.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = ae.account_id
        LEFT JOIN categories c ON c.id = at.category_id
        LEFT JOIN exchange_rates er ON (
          er.date = ae.date AND
          er.from_currency = ae.currency AND
          er.to_currency = :target_currency
        )
        WHERE at.kind NOT IN ('funds_movement', 'one_time', 'cc_payment')
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
        GROUP BY c.id, c.parent_id, CASE WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END
      SQL
    end

    def trades_subquery_sql
      # Get trades for the same family and date range as transactions
      # Only include trades that have a category assigned
      <<~SQL
        SELECT
          c.id as category_id,
          c.parent_id as parent_category_id,
          CASE WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END as classification,
          ABS(SUM(ae.amount * COALESCE(er.rate, 1))) as total,
          COUNT(ae.id) as entry_count
        FROM trades t
        JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Trade'
        JOIN accounts a ON a.id = ae.account_id
        LEFT JOIN categories c ON c.id = t.category_id
        LEFT JOIN exchange_rates er ON (
          er.date = ae.date AND
          er.from_currency = ae.currency AND
          er.to_currency = :target_currency
        )
        WHERE a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND ae.excluded = false
          AND ae.date BETWEEN :start_date AND :end_date
          AND t.category_id IS NOT NULL
        GROUP BY c.id, c.parent_id, CASE WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END
      SQL
    end

    def sql_params
      {
        target_currency: @family.currency,
        family_id: @family.id,
        start_date: @date_range.begin,
        end_date: @date_range.end
      }
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
