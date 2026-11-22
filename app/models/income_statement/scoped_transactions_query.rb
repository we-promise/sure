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
    # Contributions and loan payments are cash outflows whatever their
    # sign, so they classify as expense; other negative amounts classify as
    # income. A family that does not count investing as spending gets its
    # contributions classified as 'investment' instead, which keeps them out
    # of income and expense totals while still letting callers sum them.
    def classification_sql(t)
      contribution = @family.investment_contributions_as_spending? ? "expense" : "investment"
      "CASE WHEN #{t}.kind = 'investment_contribution' THEN '#{contribution}' WHEN #{t}.kind = 'loan_payment' THEN 'expense' WHEN ae.amount < 0 THEN 'income' ELSE 'expense' END"
    end

    # Entry amount converted to the family currency (see ExchangeRate.rate_sql).
    # Contribution/loan-payment outflows are flipped positive so they add to
    # expense totals. NULL for a currency with no rate at all, so the entry is
    # left out of a SUM rather than counted at 1. Totals wrap their SUM
    # in COALESCE so a group with nothing convertible reads 0; the stats leave
    # it NULL, so a period with nothing convertible is skipped by the median
    # and average rather than counted as a period with no spending.
    #
    # The rate comes from the fx_rates CTE (fx_rates_cte_sql), joined by
    # fx_rates_join_sql, which every query using this must include.
    def converted_amount_sql(t)
      rate = "CASE WHEN ae.currency = :target_currency THEN 1 ELSE fxr.rate END"
      "CASE WHEN #{t}.kind IN ('investment_contribution', 'loan_payment') THEN ABS(ae.amount * #{rate}) ELSE ae.amount * #{rate} END"
    end

    # One rate per (currency, date) for the entries a query converts, by
    # ExchangeRate.rate_sql's rule, so each pair is looked up once rather than
    # once per entry. transactions_scope: the query's own transactions, for
    # exactly their pairs; it must join `entries` unaliased, since the pairs
    # read entries.currency and entries.date. Without it, every entry of the
    # family, which covers any query over the family's transactions.
    def fx_rates_cte_sql(transactions_scope = nil)
      if transactions_scope && !joins_entries?(transactions_scope)
        raise ArgumentError, "transactions_scope must join entries to collect its exchange rate pairs"
      end

      pairs = if transactions_scope
        transactions_scope.unscope(:select, :order)
                          .where.not(entries: { currency: @family.currency })
                          .select("entries.currency AS currency, entries.date AS date")
                          .distinct
                          .to_sql
      else
        <<~SQL.squish
          SELECT DISTINCT fx_e.currency, fx_e.date
          FROM entries fx_e JOIN accounts fx_a ON fx_a.id = fx_e.account_id
          WHERE fx_a.family_id = :family_id AND fx_e.currency <> :target_currency
        SQL
      end

      "fx_rates AS MATERIALIZED (#{ExchangeRate.rates_by_pair_sql(pairs_sql: pairs, to: ":target_currency")})"
    end

    def fx_rates_join_sql
      "LEFT JOIN fx_rates fxr ON fxr.currency = ae.currency AND fxr.date = ae.date"
    end

    def joins_entries?(relation)
      relation.arel.join_sources.any? { |join| join.left.respond_to?(:name) && join.left.name.to_s == "entries" }
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

    # Scheduled (future-dated) entries haven't happened yet, so "actual"
    # reporting shouldn't count them -- see Entry#excluding_scheduled. Only
    # needed by the queries here that build their own SQL directly against
    # `transactions`/`entries` (FamilyStats, CategoryStats); Totals and
    # DailyExpenseTotals instead select from a caller-supplied
    # `transactions_scope`, which already carries this exclusion (see
    # IncomeStatement#totals/#totals_for_period).
    def excluding_scheduled_sql
      "AND ae.date <= :today"
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
      { target_currency: @family.currency, family_id: @family.id, today: Date.current }.merge(extra).tap do |params|
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
