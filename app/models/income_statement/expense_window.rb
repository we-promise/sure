# What was actually spent between two dates, in family currency.
#
# FamilyStats answers "what does a typical month look like" by taking a median
# across every month on record. That is the wrong question for a reserve sized
# in months of expenses: a household with eight years of partial imports has
# most of its months near zero, and the median lands on one of them.
#
# This answers the literal question instead — the total over a stated window —
# and shares the same WHERE fragments so the two cannot disagree about what
# counts as spending.
class IncomeStatement::ExpenseWindow
  include IncomeStatement::ExpensePredicates

  # `category_ids` nil means every category, which is what an unconfigured
  # reserve wants. An empty array would mean "none at all" and is treated the
  # same as nil, so a goal that has selected nothing still gets a figure rather
  # than a silent zero.
  def initialize(family, date_range:, account_ids: nil, category_ids: nil, include_uncategorized: false)
    @family = family
    @date_range = date_range
    @account_ids = account_ids
    @category_ids = category_ids.presence
    @include_uncategorized = include_uncategorized
  end

  # @return [BigDecimal] total expenses over the window, never negative
  def total
    return 0.to_d if @account_ids&.empty?

    value = ActiveRecord::Base.connection.select_value(sanitized_query_sql).to_d
    value.positive? ? value : 0.to_d
  end

  private
    def sanitized_query_sql
      ActiveRecord::Base.sanitize_sql_array([ query_sql, sql_params ])
    end

    def sql_params
      {
        target_currency: @family.currency,
        family_id: @family.id,
        start_date: @date_range.begin,
        end_date: @date_range.end
      }.merge(tax_advantaged_params)
    end

    # Only meaningful alongside a category list: with no list every transaction
    # counts, categorised or not.
    def category_filter_sql
      return "" if @category_ids.nil?

      clause = ActiveRecord::Base.sanitize_sql([ "t.category_id IN (?)", @category_ids ])
      clause += " OR t.category_id IS NULL" if @include_uncategorized
      "AND (#{clause})"
    end

    # Same classification as FamilyStats: an inflow carries a negative amount,
    # and the two kinds below are outflows recorded the other way round.
    CLASSIFICATION_SQL = <<~SQL.squish
      CASE WHEN t.kind IN ('investment_contribution', 'loan_payment') THEN 'expense'
           WHEN ae.amount < 0 THEN 'income'
           ELSE 'expense' END
    SQL

    AMOUNT_SQL = <<~SQL.squish
      CASE WHEN t.kind IN ('investment_contribution', 'loan_payment')
           THEN ABS(ae.amount * COALESCE(er.rate, 1))
           ELSE ae.amount * COALESCE(er.rate, 1) END
    SQL

    def query_sql
      <<~SQL
        SELECT COALESCE(SUM(#{AMOUNT_SQL}), 0) AS total
        FROM transactions t
        JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = ae.account_id
        LEFT JOIN exchange_rates er ON (
          er.date = ae.date AND
          er.from_currency = ae.currency AND
          er.to_currency = :target_currency
        )
        WHERE a.family_id = :family_id
          AND ae.date >= :start_date
          AND ae.date <= :end_date
          AND t.kind NOT IN (#{budget_excluded_kinds_sql})
          AND ae.excluded = false
          AND a.exclude_from_reports = false
          AND (#{CLASSIFICATION_SQL}) = 'expense'
          #{pending_providers_sql}
          #{exclude_tax_advantaged_sql}
          #{scope_to_account_ids_sql}
          #{category_filter_sql}
      SQL
    end
end
