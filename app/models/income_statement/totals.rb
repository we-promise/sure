class IncomeStatement::Totals
  # Bump when TotalsRow changes: persisted rows must deserialize with this shape.
  CACHE_VERSION = "v3"

  include IncomeStatement::ScopedTransactionsQuery

  # windows: date ranges to total separately in the same query (see
  # #call_by_window). The scope must cover all of them.
  def initialize(family, transactions_scope:, date_range:, include_trades: true, included_account_ids: nil, group_by_month: false, windows: nil)
    @family = family
    @transactions_scope = transactions_scope
    @date_range = date_range
    @include_trades = include_trades
    @included_account_ids = included_account_ids
    @group_by_month = group_by_month
    @windows = windows

    raise ArgumentError, "group_by_month requires include_trades" if @group_by_month && !@include_trades
    raise ArgumentError, "windows and group_by_month can't be combined" if @windows && @group_by_month

    validate_date_range!
  end

  def call
    # No finance accounts means no transactions to report
    return [] if @included_account_ids&.empty?

    ActiveRecord::Base.connection.select_all(query_sql).map { |row| totals_row(row) }
  end

  # The rows #call would return for each of the windows, in their order, from
  # one query. An entry counts in every window its date falls in.
  def call_by_window
    raise ArgumentError, "call_by_window needs windows" if @windows.blank?

    rows = Array.new(@windows.size) { [] }
    return rows if @included_account_ids&.empty?

    ActiveRecord::Base.connection.select_all(query_sql).each do |row|
      rows[row["window_idx"].to_i] << totals_row(row)
    end
    rows
  end

  private
    TotalsRow = Data.define(:parent_category_id, :category_id, :classification, :total, :transactions_count, :is_uncategorized_investment, :month) do
      def initialize(month: nil, **rest) = super
    end

    def totals_row(row)
      TotalsRow.new(
        parent_category_id: row["parent_category_id"],
        category_id: row["category_id"],
        classification: row["classification"],
        total: row["total"],
        transactions_count: row["transactions_count"],
        is_uncategorized_investment: row["is_uncategorized_investment"],
        month: row["month"]&.to_date
      )
    end

    # With windows, each entry is joined to every window its date falls in and
    # the rows are grouped by window as well.
    def window_column_sql
      @windows ? "w.idx as window_idx," : ""
    end

    def window_group_sql
      @windows ? "w.idx," : ""
    end

    def windows_join_sql
      return "" unless @windows

      connection = ActiveRecord::Base.connection
      values = @windows.each_with_index.map do |range, idx|
        "(#{idx}, #{connection.quote(range.begin.to_date)}::date, #{connection.quote(range.end.to_date)}::date)"
      end
      "JOIN (VALUES #{values.join(", ")}) w(idx, start_date, end_date) ON ae.date BETWEEN w.start_date AND w.end_date"
    end

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
          #{@windows ? "window_idx," : ""}
          category_id,
          parent_category_id,
          classification,
          is_uncategorized_investment,
          #{"month," if @group_by_month}
          SUM(total) as total,
          SUM(entry_count) as transactions_count
        FROM (
          #{transactions_subquery_sql}
          UNION ALL
          #{trades_subquery_sql}
        ) combined
        GROUP BY #{@windows ? "window_idx," : ""} category_id, parent_category_id, classification, is_uncategorized_investment#{", month" if @group_by_month};
      SQL
    end

    # Original transactions-only query (for backwards compatibility)
    def transactions_only_query_sql
      <<~SQL
        SELECT
          #{window_column_sql}
          c.id as category_id,
          c.parent_id as parent_category_id,
          #{classification_sql("at")} as classification,
          ABS(COALESCE(SUM(#{converted_amount_sql("at")}), 0)) as total,
          COUNT(ae.id) as transactions_count,
          false as is_uncategorized_investment
        FROM (#{@transactions_scope.to_sql}) at
        #{entries_join_sql("at")}
        #{accounts_join_sql}
        LEFT JOIN categories c ON c.id = at.category_id
        #{windows_join_sql}
        WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
        GROUP BY #{window_group_sql} c.id, c.parent_id, #{classification_sql("at")};
      SQL
    end

    def transactions_subquery_sql
      <<~SQL
        SELECT
          #{window_column_sql}
          c.id as category_id,
          c.parent_id as parent_category_id,
          #{classification_sql("at")} as classification,
          ABS(COALESCE(SUM(#{converted_amount_sql("at")}), 0)) as total,
          COUNT(ae.id) as entry_count,
          false as is_uncategorized_investment#{",\n          date_trunc('month', ae.date)::date as month" if @group_by_month}
        FROM (#{@transactions_scope.to_sql}) at
        #{entries_join_sql("at")}
        #{accounts_join_sql}
        LEFT JOIN categories c ON c.id = at.category_id
        #{windows_join_sql}
        WHERE at.kind NOT IN (#{budget_excluded_kinds_sql})
          #{investment_activity_label_sql("at")}
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
        GROUP BY #{window_group_sql} c.id, c.parent_id, #{classification_sql("at")}#{", date_trunc('month', ae.date)::date" if @group_by_month}
      SQL
    end

    def trades_subquery_sql
      # Trades are completely excluded from income/expense budgets
      # Rationale: Trades represent portfolio rebalancing, not cash flow
      # Example: Selling $10k AAPL to buy MSFT = no net worth change, not an expense
      # Contributions/withdrawals are tracked separately as Transactions with activity labels
      <<~SQL
        SELECT #{@windows ? "NULL as window_idx," : ""} NULL as category_id, NULL as parent_category_id, NULL as classification,
               NULL as total, NULL as entry_count, NULL as is_uncategorized_investment#{",\n               NULL::date as month" if @group_by_month}
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
