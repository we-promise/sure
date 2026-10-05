# SQL building blocks shared by the IncomeStatement query classes
# (Totals, DailyExpenseTotals, FamilyStats, CategoryStats). Each class keeps
# its own SELECT/FROM/GROUP BY, but the scoping fragments - which rows count
# as reportable transactions and how amounts convert to the family
# currency - live here so every income statement number on the dashboard is
# computed the same way.
#
# Fragments are parameterized by `t`, the alias the calling query gives its
# transactions table or scope subquery, and assume the entry and account
# aliases (`ae`, `a`). The including class must set `@family`.
module IncomeStatement::ScopedTransactionsQuery
  private
    # Contributions and loan payments are cash outflows recorded as negative
    # amounts, so they always classify as expense; other negative amounts
    # classify as income.
    def classification_sql(t)
      "CASE WHEN #{t}.kind IN ('investment_contribution', 'loan_payment') THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END"
    end

    # Entry amount converted to the family currency (see ExchangeRate.rate_sql).
    # Contribution/loan-payment outflows are flipped positive so they add to
    # expense totals. NULL for a currency with no rate at all, so the entry is
    # left out of a SUM rather than counted at 1 (#3640). Totals wrap their SUM
    # in COALESCE so a group with nothing convertible reads 0; the stats leave
    # it NULL, so a period with nothing convertible is skipped by the median
    # and average rather than counted as a period with no spending.
    def converted_amount_sql(t)
      rate = ExchangeRate.rate_sql(from: "ae.currency", to: ":target_currency", on: "ae.date")
      "CASE WHEN #{t}.kind IN ('investment_contribution', 'loan_payment') THEN ABS(ae.amount * #{rate}) ELSE ae.amount * #{rate} END"
    end

    def entries_join_sql(t)
      "JOIN entries ae ON ae.entryable_id = #{t}.id AND ae.entryable_type = 'Transaction'"
    end

    def accounts_join_sql
      "JOIN accounts a ON a.id = ae.account_id"
    end

    # Investment activity rows that move money within a portfolio
    # (transfers, sweeps, exchanges) are neither income nor expenses.
    def investment_activity_label_sql(t)
      <<~SQL.chomp
        AND (
          #{t}.investment_activity_label IS NULL
          OR #{t}.investment_activity_label NOT IN ('Transfer', 'Sweep In', 'Sweep Out', 'Exchange')
        )
      SQL
    end

    def budget_excluded_kinds_sql
      @budget_excluded_kinds_sql ||= Transaction::BUDGET_EXCLUDED_KINDS.map { |k| "'#{k}'" }.join(", ")
    end

    def pending_providers_sql(t = "t")
      Transaction.pending_providers_sql(t)
    end

    # Tax-advantaged accounts (401k, IRA, HSA, etc.) are retirement savings,
    # not daily expenses, so they're excluded from budget calculations.
    def exclude_tax_advantaged_sql
      ids = @family.tax_advantaged_account_ids
      return "" if ids.empty?
      "AND a.id NOT IN (:tax_advantaged_account_ids)"
    end

    # Named-parameter account scoping, for queries bound with sql_params.
    def include_finance_accounts_sql
      return "" if @included_account_ids.nil?
      "AND a.id IN (:included_account_ids)"
    end

    # Inlined account scoping, for queries built with sanitize_sql.
    def scope_to_account_ids_sql
      return "" if @account_ids.nil?
      ActiveRecord::Base.sanitize_sql([ "AND a.id IN (?)", @account_ids ])
    end

    # Bind params every income statement query needs; classes merge their
    # extras (date range, interval, account ids) on top.
    def base_sql_params(extra = {})
      { target_currency: @family.currency, family_id: @family.id }.merge(extra).tap do |params|
        ids = @family.tax_advantaged_account_ids
        params[:tax_advantaged_account_ids] = ids if ids.present?
      end
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
