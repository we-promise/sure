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

    # Entry amount converted to the family currency at the day's exchange
    # rate. Contribution/loan-payment outflows are flipped positive so they
    # add to expense totals.
    def converted_amount_sql(t)
      "CASE WHEN #{t}.kind IN ('investment_contribution', 'loan_payment') THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE ae.amount * COALESCE(er.rate, 1) END"
    end

    def entries_join_sql(t)
      "JOIN entries ae ON ae.entryable_id = #{t}.id AND ae.entryable_type = 'Transaction'"
    end

    def accounts_join_sql
      "JOIN accounts a ON a.id = ae.account_id"
    end

    # Rate used to convert an entry into the family currency.
    #
    # Joining on exact date equality left a transaction with no rate row for
    # its own date matching nothing, and the `COALESCE(er.rate, 1)` in
    # converted_amount_sql then converted it 1:1 - an NZD 117 expense showed as
    # ¥117 against a CNY budget. Rates are only stored for days a provider
    # published one, so any weekend, holiday or gap in an import hit this.
    #
    # Take the most recent rate for the pair within a bounded backward window
    # instead, so the join yields NULL (and COALESCE falls back to 1:1) only
    # when the pair has no rate near the entry date at all. The window mirrors
    # ExchangeRate::Provided#find_or_fetch_rate, so SQL and Ruby agree on which
    # rate is close enough to reuse; unbounded, a years-old import would
    # silently convert today's transaction at a stale rate.
    #
    # Looking backward only also matches the Ruby path: a future-dated entry
    # keeps the 1:1 fallback until a rate on or before its date is stored.
    #
    # The unique index on (from_currency, to_currency, date) serves the
    # subquery, so the per-row cost stays negligible.
    def exchange_rates_join_sql
      <<~SQL.chomp
        LEFT JOIN LATERAL (
          SELECT rate
          FROM exchange_rates
          WHERE from_currency = ae.currency
            AND to_currency = :target_currency
            AND date BETWEEN ae.date - :nearest_rate_lookback_days AND ae.date
          ORDER BY date DESC
          LIMIT 1
        ) er ON true
      SQL
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
      {
        target_currency: @family.currency,
        family_id: @family.id,
        nearest_rate_lookback_days: ExchangeRate::Provided::NEAREST_RATE_LOOKBACK_DAYS
      }.merge(extra).tap do |params|
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
