# Net spending per category for a period, compared with what is normal for
# that category: its net spending over the year before the period, scaled to
# the period's length. Feeds the "Spending vs normal" Reports section.
#
# Net means expense minus refunds in the same category, the way the cash flow
# Sankey nets them, so a refunded purchase doesn't count as spending. Totals
# come from the user-scoped IncomeStatement, so transfers, exclusions and
# account sharing follow the rest of Reports.
class IncomeStatement::SpendingComparison
  BASELINE_LENGTH = 1.year
  # Below this much history before the period there is nothing meaningful to
  # compare against, so `normal` is nil.
  MIN_BASELINE_DAYS = 28

  Row = Data.define(:category, :total, :normal, :subcategories) do
    def change
      normal && total - normal
    end

    # Fractional change against normal (0.5 = 50% more); nil without a normal.
    def ratio
      return nil unless normal&.positive?

      (total - normal) / normal
    end
  end

  attr_reader :period, :baseline_period

  # The first transaction these totals could count: in the statement's
  # eligible accounts and not excluded, as IncomeStatement::Totals filters.
  # Opening-balance valuations can predate real activity by years, accounts
  # outside the user's finances aren't counted, and an excluded old entry
  # isn't spending, so any of them would dilute "normal" with empty months.
  def self.history_start(income_statement)
    Entry.where(account_id: income_statement.eligible_accounts.select(:id), entryable_type: "Transaction", excluded: false)
         .minimum(:date)
  end

  def initialize(income_statement, period:, history_start:)
    @income_statement = income_statement
    @period = period
    @baseline_period = build_baseline_period(history_start)
  end

  def comparable?
    baseline_period.present?
  end

  # Parent categories (and the synthetic Uncategorized) with net spending in
  # the period or a normal above zero, largest first. Each row's subcategories
  # include one for spending booked on the parent itself, so the subcategory
  # totals add up to the row total.
  def rows
    @rows ||= begin
      current = net_by_category(period)
      baseline = comparable? ? net_by_category(baseline_period) : {}

      parents = (current.values + baseline.values).map { |e| e[:category] }
        .reject(&:subcategory?).uniq { |c| key_for(c) }

      parents.filter_map { |parent| build_row(parent, current, baseline) }
        .sort_by { |row| -row.total }
    end
  end

  def total
    rows.sum(&:total)
  end

  def normal_total
    comparable? ? rows.sum { |row| row.normal || 0 } : nil
  end

  private
    attr_reader :income_statement

    def build_baseline_period(history_start)
      end_date = period.start_date - 1.day
      start_date = [ period.start_date - BASELINE_LENGTH, history_start || period.start_date ].max
      return nil if (end_date - start_date).to_i + 1 < MIN_BASELINE_DAYS

      Period.custom(start_date: start_date, end_date: end_date)
    end

    def build_row(parent, current, baseline)
      key = key_for(parent)
      children = (current.values + baseline.values).map { |e| e[:category] }
        .select { |c| c.subcategory? && c.parent_id == parent.id }.uniq(&:id)

      total = positive(current.dig(key, :net))
      normal = scaled_normal(baseline.dig(key, :net))
      return nil if total.zero? && !normal&.positive?

      subcategories = children.filter_map do |child|
        child_total = positive(current.dig(child.id, :net))
        child_normal = scaled_normal(baseline.dig(child.id, :net))
        next if child_total.zero? && !child_normal&.positive?

        Row.new(category: child, total: child_total, normal: child_normal, subcategories: [])
      end

      # Refunds can push a subcategory's net below zero, which lowers the
      # parent total but is clamped out of the subcategories. When the rest
      # then add up to more than the parent, show the parent as one box so
      # the treemap never overstates it.
      subcategories = [] if subcategories.sum(&:total) > total

      direct_total = [ total - subcategories.sum(&:total), 0 ].max
      direct_normal = normal && [ normal - subcategories.sum { |s| s.normal || 0 }, 0 ].max
      if direct_total.positive? || direct_normal&.positive?
        subcategories << Row.new(category: parent, total: direct_total, normal: direct_normal, subcategories: [])
      end

      Row.new(category: parent, total: total, normal: normal, subcategories: subcategories.sort_by { |s| -s.total })
    end

    # { key => { category:, net: } } for every category with activity, where
    # net = expense - income booked to that category in the period.
    def net_by_category(p)
      result = {}
      { income_statement.expense_totals(period: p) => 1, income_statement.income_totals(period: p) => -1 }.each do |totals, sign|
        totals.category_totals.each do |ct|
          next if ct.total.zero?

          entry = result[key_for(ct.category)] ||= { category: ct.category, net: 0 }
          entry[:net] += sign * ct.total
        end
      end
      result
    end

    def scaled_normal(baseline_net)
      return nil unless comparable?

      positive(baseline_net) * period_days / baseline_days
    end

    def period_days
      (period.end_date - period.start_date).to_i + 1
    end

    def baseline_days
      (baseline_period.end_date - baseline_period.start_date).to_i + 1
    end

    def positive(value)
      [ value || 0, 0 ].max
    end

    def key_for(category)
      return :uncategorized if category.uncategorized?
      return :other_investments if category.other_investments?

      category.id
    end
end
