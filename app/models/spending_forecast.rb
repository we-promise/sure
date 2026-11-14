# Predicts the spending Bills doesn't track: each expense category's typical
# month (the median of the last full months, so one big trip doesn't become
# a monthly habit), less what it has spent so far this month.
# Transactions a bill fully covers are left out, because Bills already
# forecasts them, and so are partial months before the family's first
# transaction.
class SpendingForecast
  HISTORY_MONTHS = 3

  Row = Data.define(:category, :typical, :spent, :remaining)

  attr_reader :family, :user, :today

  def initialize(family, user: nil, today: Date.current)
    @family = family
    @user = user
    @today = today
  end

  # Top-level categories, largest typical month first. A nil category is
  # uncategorized spending.
  def rows
    @rows ||= begin
      spent = totals_by_category(today.beginning_of_month..today)
      months = history_ranges.map { |range| totals_by_category(range) }
      category_ids = months.flat_map(&:keys).uniq
      categories = family.categories.where(id: category_ids.compact).index_by(&:id)

      category_ids.filter_map do |category_id|
        typical = median(months.map { |totals| totals.fetch(category_id, 0) })
        next unless typical.positive?

        spent_so_far = spent.fetch(category_id, 0)
        Row.new(
          category: categories[category_id],
          typical: money(typical),
          spent: money(spent_so_far),
          remaining: money([ typical - spent_so_far, 0 ].max)
        )
      end.sort_by { |row| -row.typical.amount }
    end
  end

  def any?
    rows.any?
  end

  def remaining_this_month
    money(rows.sum { |row| row.remaining.amount })
  end

  def next_month
    money(rows.sum { |row| row.typical.amount })
  end

  def history_months
    @history_months ||= begin
      first_date = family.entries.where(entryable_type: "Transaction").minimum(:date)
      if first_date.nil?
        0
      else
        first_full_month = first_date == first_date.beginning_of_month ? first_date : first_date.next_month.beginning_of_month
        start = [ today.beginning_of_month - HISTORY_MONTHS.months, first_full_month ].max
        [ (today.year * 12 + today.month) - (start.year * 12 + start.month), 0 ].max
      end
    end
  end

  private
    def history_ranges
      (1..history_months).map do |ago|
        start = today.beginning_of_month - ago.months
        start..start.end_of_month
      end
    end

    def median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    end

    def totals_by_category(range)
      scope = family.transactions.visible.excluding_pending
                    .merge(Entry.excluding_scheduled)
                    .merge(Entry.where(date: range))
                    .where.not(entries: { id: bill_entry_ids })

      IncomeStatement::Totals.new(
        family,
        transactions_scope: scope,
        date_range: range,
        included_account_ids: account_ids
      ).call
        .select { |row| row.classification == "expense" }
        .group_by { |row| row.parent_category_id || row.category_id }
        .transform_values { |rows| rows.sum { |row| row.total.to_d } }
    end

    # A partly allocated entry stays in whole, so its bill share counts twice;
    # dropping it would lose the unallocated rest, the larger error. Coverage
    # is measured in the entry's currency (source_amount), so a cross-currency
    # allocation without an exchange rate covers nothing, and allocations from
    # ended bills don't count, as in the allocator's capacity checks.
    def bill_entry_ids
      RecurringAllocation.confirmed
                         .joins(:entry, recurring_occurrence: :recurring_transaction)
                         .where(recurring_occurrences: { family_id: family.id })
                         .where.not(recurring_transactions: { status: "ended" })
                         .group("recurring_allocations.entry_id", "entries.amount")
                         .having("SUM(recurring_allocations.source_amount) >= ABS(entries.amount)")
                         .select("recurring_allocations.entry_id")
    end

    def account_ids
      @account_ids ||= IncomeStatement.new(family, user: user).eligible_accounts.pluck(:id)
    end

    def money(amount)
      Money.new(amount, family.currency)
    end
end
