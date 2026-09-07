class IncomeStatement::Totals
  include IncomeStatement::TransferFiltering
  include IncomeStatement::ScopedTransactionsQuery

  def initialize(family, transactions_scope:, date_range:, include_trades: true, included_account_ids: nil, include_investment_contributions: true)
    @family = family
    @transactions_scope = transactions_scope
    @date_range = date_range
    @include_trades = include_trades
    @included_account_ids = included_account_ids
    @include_investment_contributions = include_investment_contributions

    validate_date_range!
  end

  def call
    # No finance accounts means no transactions to report
    return [] if @included_account_ids&.empty?

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
          #{classification_sql("at")} as classification,
          ABS(SUM(#{converted_amount_sql("at")})) as total,
          COUNT(ae.id) as transactions_count,
          false as is_uncategorized_investment
        FROM (#{@transactions_scope.to_sql}) at
        #{entries_join_sql("at")}
        #{accounts_join_sql}
        LEFT JOIN categories c ON c.id = at.category_id
        #{exchange_rates_join_sql}
        WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
          AND (#{transfer_filter_sql("at")})
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
        GROUP BY c.id, c.parent_id, #{classification_sql("at")};
      SQL
    end

    def transactions_subquery_sql
      <<~SQL
        SELECT
          c.id as category_id,
          c.parent_id as parent_category_id,
          #{classification_sql("at")} as classification,
          ABS(SUM(#{converted_amount_sql("at")})) as total,
          COUNT(ae.id) as entry_count,
          false as is_uncategorized_investment
        FROM (#{@transactions_scope.to_sql}) at
        #{entries_join_sql("at")}
        #{accounts_join_sql}
        LEFT JOIN categories c ON c.id = at.category_id
        #{exchange_rates_join_sql}
        WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
          AND (#{transfer_filter_sql("at")})
          #{investment_activity_label_sql("at")}
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
        GROUP BY c.id, c.parent_id, #{classification_sql("at")}
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
      params = base_sql_params(start_date: @date_range.begin, end_date: @date_range.end)

      # Add included account IDs for per-user finance scoping
      params[:included_account_ids] = @included_account_ids if @included_account_ids

      params
    end
end
