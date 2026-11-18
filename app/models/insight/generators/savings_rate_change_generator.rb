# Compares the savings rate of the last three complete months with that of
# the three before. A monthly rate mostly measures which day the salary
# landed: paid on the 29th instead of the 1st, one month gets two salaries and
# the next none. So each window's income is its median month times three, which
# ignores a paycheck that moved to a neighbouring month wherever it falls,
# while spending is summed so a real one-off cost still shows. The current
# (partial) month is skipped for the same reason.
class Insight::Generators::SavingsRateChangeGenerator < Insight::Generator
  produces "savings_rate_change"

  WINDOW_MONTHS = 3
  THRESHOLD_PP = 5
  HIGH_PRIORITY_PP = 10

  def generate
    last_month = Period.last_month_for(family)
    window_start = last_month.start_date - (WINDOW_MONTHS - 1).months
    window = Period.custom(start_date: window_start, end_date: last_month.end_date)

    current_rate = savings_rate(window_start)
    previous_rate = savings_rate(window_start - WINDOW_MONTHS.months)
    return [] unless current_rate && previous_rate

    delta = current_rate - previous_rate
    return [] if delta.abs < THRESHOLD_PP

    direction = delta.positive? ? "up" : "down"

    # "You saved -5.4% of your income" is machine-speak: when the family spent
    # more than it earned, the copy says so. Decided on the window's actual
    # totals, since the median-based rate can be negative after a bonus month.
    template_key = if direction == "down" && current_rate.negative? && spent_more_than_earned?(window_start)
      "savings_rate_change.down_negative"
    else
      "savings_rate_change.#{direction}"
    end

    [
      build_insight(
        insight_type: "savings_rate_change",
        priority: delta.abs >= HIGH_PRIORITY_PP ? "high" : "medium",
        title: I18n.t("insights.titles.savings_rate_change.#{direction}"),
        template_key: template_key,
        facts: {
          from_month: window_bound(window.start_date, window.start_date),
          to_month: window_bound(last_month.start_date, window.end_date),
          current_rate: signed_number(round(current_rate, 1)),
          previous_rate: signed_number(round(previous_rate, 1)),
          change_pp: round(delta.abs, 1)
        },
        # Both windows hold only complete months, so these stay put for the
        # whole month and the nightly run doesn't reopen a dismissal. "v2"
        # because month-against-month rows still carry this month's key.
        metadata: {
          current_rate: round(current_rate, 1),
          previous_rate: round(previous_rate, 1),
          accounts_digest: shared_accounts_digest
        },
        period: window,
        dedup_key: "savings_rate_change:v2:#{month_token(last_month.start_date)}"
      )
    ]
  end

  private
    # The rate of the window of WINDOW_MONTHS months starting on `start_date`.
    def savings_rate(start_date)
      incomes, expense = window_totals(start_date)
      income = incomes.sort[WINDOW_MONTHS / 2] * WINDOW_MONTHS # the median: WINDOW_MONTHS is odd
      return nil if income <= 0

      (income - expense) / income * 100
    end

    def spent_more_than_earned?(start_date)
      incomes, expense = window_totals(start_date)
      expense > incomes.sum
    end

    # [each month's income, the window's summed spending]. Transfers into
    # savings accounts are budget expenses, but they are money saved, not
    # spent, so they don't count as spending here.
    def window_totals(start_date)
      months = Array.new(WINDOW_MONTHS) do |i|
        month_start = start_date + i.months
        Period.custom(start_date: month_start, end_date: month_start + 1.month - 1.day)
      end

      [
        months.map { |month| income_statement.income_totals(period: month).total.to_d },
        months.sum do |month|
          income_statement.expense_totals(period: month).total.to_d -
            income_statement.savings_contributions_total(period: month).to_d
        end
      ]
    end

    # Month names for calendar months; for months that start on another day
    # (a custom month start) the window's dates, which month names would
    # misreport.
    def window_bound(month_start, date)
      if month_start == month_start.beginning_of_month
        I18n.l(month_start, format: "%B")
      else
        I18n.l(date, format: :short)
      end
    end
end
