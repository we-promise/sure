# Net spending per category for a period, compared with what is normal for
# that category: its net spending over the year before the period, scaled to
# the period's length. An unfinished period (the default current month)
# counts spending so far and compares it with the same number of days from
# each of the 12 month starts before it. Feeds the "Spending vs normal"
# Reports section.
#
# Net means expense minus refunds in the same category, the way the cash flow
# Sankey nets them, so a refunded purchase doesn't count as spending. Totals
# come from the user-scoped IncomeStatement, so transfers, exclusions and
# account sharing follow the rest of Reports.
#
# as_json is the shared representation for the public API (for the mobile
# app); the Reports section renders the same rows.
class IncomeStatement::SpendingComparison
  BASELINE_LENGTH = 1.year
  # Below this much history before the period there is nothing meaningful to
  # compare against, so `normal` is nil.
  MIN_BASELINE_DAYS = 28

  # Changes smaller than this are left out of the change list.
  MIN_CHANGE = 1

  # direct: a parent's own spending (booked on the parent, not a
  # subcategory), listed among its subcategories.
  Row = Data.define(:category, :total, :normal, :subcategories, :direct) do
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

  delegate :currency, to: :income_statement

  # The first transaction these totals could count, filtered as
  # IncomeStatement::Totals filters: in the statement's eligible accounts, not
  # excluded, not pending, and not a kind analytics skip (transfers, card
  # payments, and investment contributions when investing isn't counted as
  # spending). Opening-balance valuations, an early transfer or an excluded
  # entry can predate real spending by years, and would dilute "normal" with
  # empty months.
  def self.history_start(income_statement)
    Entry.joins("JOIN transactions ON transactions.id = entries.entryable_id")
         .where(account_id: income_statement.eligible_accounts.select(:id), entryable_type: "Transaction", excluded: false)
         .merge(Transaction.excluding_pending)
         .where.not(transactions: { kind: income_statement.family.analytics_excluded_kinds })
         .minimum(:date)
  end

  def initialize(income_statement, period:, history_start:, as_of: Date.current)
    @income_statement = income_statement
    @in_progress = period.start_date <= as_of && as_of < period.end_date
    # An unfinished period counts spending so far.
    @period = @in_progress ? Period.custom(start_date: period.start_date, end_date: as_of) : period
    @baseline_period = build_baseline_period(history_start)
  end

  def in_progress?
    @in_progress
  end

  def comparable?
    baseline_period.present? && (!in_progress? || baseline_windows.any?)
  end

  # Parent categories (and the synthetic Uncategorized) with net spending in
  # the period or a normal above zero, largest first. Each row's subcategories
  # include one for spending booked on the parent itself, so the subcategory
  # totals add up to the row total.
  def rows
    @rows ||= begin
      current = net_by_category(period)
      baseline = comparable? ? baseline_net : {}

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

  # Parent rows changed by at least MIN_CHANGE against normal, most increased
  # first. Empty without a normal.
  def changes
    rows.select { |row| row.change && row.change.abs >= MIN_CHANGE }.sort_by { |row| -row.change }
  end

  # Rows the treemap draws: positive totals only, at both levels.
  def drawable_rows
    rows.select { |row| row.total.positive? }.map do |row|
      row.with(subcategories: row.subcategories.select { |sub| sub.total.positive? })
    end
  end

  # Amounts are decimal strings in the statement currency; ratio is a decimal
  # string too (0.5 = 50% more than normal). A parent's own spending, booked on
  # the parent rather than a subcategory, is listed among its subcategories
  # with the parent's id, so the subcategories add up to the parent.
  def as_json(*)
    {
      currency: currency,
      period: period_json(period),
      in_progress: in_progress?,
      baseline_period: baseline_period && period_json(baseline_period),
      comparable: comparable?,
      total: decimal(total),
      normal_total: normal_total && decimal(normal_total),
      categories: rows.map { |row| row_json(row).merge(subcategories: row.subcategories.map { |sub| row_json(sub).merge(direct: sub.direct) }) }
    }
  end

  # One row in the shared representation (see as_json).
  def row_json(row)
    {
      id: row.category.id,
      name: row.category.name,
      color: row.category.color,
      filter_value: row.category.filter_value,
      total: decimal(row.total),
      normal: row.normal && decimal(row.normal),
      change: row.change && decimal(row.change),
      ratio: row.ratio && decimal(row.ratio.round(4))
    }
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

        Row.new(category: child, total: child_total, normal: child_normal, subcategories: [], direct: false)
      end

      # Refunds can push a subcategory's net below zero, which lowers the
      # parent total but is clamped out of the subcategories. When the rest
      # then add up to more than the parent, show the parent as one box so
      # the treemap never overstates it.
      subcategories = [] if subcategories.sum(&:total) > total

      direct_total = [ total - subcategories.sum(&:total), 0 ].max
      direct_normal = normal && [ normal - subcategories.sum { |s| s.normal || 0 }, 0 ].max
      if direct_total.positive? || direct_normal&.positive?
        subcategories << Row.new(category: parent, total: direct_total, normal: direct_normal, subcategories: [], direct: true)
      end

      Row.new(category: parent, total: total, normal: normal, subcategories: subcategories.sort_by { |s| -s.total }, direct: false)
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
      return positive(baseline_net) if in_progress? # already an average of same-length windows

      positive(baseline_net) * period_days / baseline_days
    end

    # A whole period compares with the baseline year scaled to its length. An
    # unfinished one compares with the same number of days from each of the
    # 12 month starts before it, so a bill paid on the 1st counts the same in
    # both and early-month spending isn't measured against a whole month.
    def baseline_net
      return net_by_category(baseline_period) unless in_progress?

      baseline_windows.map { |w| net_by_category(w) }.each_with_object({}) do |net, avg|
        net.each { |key, e| (avg[key] ||= { category: e[:category], net: 0 })[:net] += e[:net] / baseline_windows.size }
      end
    end

    def baseline_windows
      @baseline_windows ||= (1..12).filter_map do |i|
        start = period.start_date - i.months
        finish = start + (period_days - 1).days
        # A window that runs into the period would count the spending it's compared with
        Period.custom(start_date: start, end_date: finish) if start >= baseline_period.start_date && finish <= baseline_period.end_date
      end
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

    def period_json(p)
      { start_date: p.start_date.iso8601, end_date: p.end_date.iso8601 }
    end

    def decimal(value)
      value.to_d.to_s("F")
    end

    def key_for(category)
      return :uncategorized if category.uncategorized?
      return :other_investments if category.other_investments?

      category.id
    end
end
