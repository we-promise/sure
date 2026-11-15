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

    # "You saved -5.4% of your income" is machine-speak; a negative rate means
    # the family spent more than it earned, and the copy should say so.
    template_key = if direction == "down" && current_rate.negative?
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
          from_month: I18n.l(window.start_date, format: "%B"),
          to_month: I18n.l(last_month.start_date, format: "%B"),
          current_rate: signed_number(round(current_rate, 1)),
          previous_rate: signed_number(round(previous_rate, 1)),
          change_pp: round(delta.abs, 1)
        },
        # Both windows hold only complete months, so these stay put for the
        # whole month and the nightly run doesn't reopen a dismissal. "v2"
        # because month-against-month rows still carry this month's key.
        metadata: {
          current_rate: round(current_rate, 1),
          previous_rate: round(previous_rate, 1)
        },
        period: window,
        dedup_key: "savings_rate_change:v2:#{month_token(last_month.start_date)}"
      )
    ]
  end

  private
    # The rate of the window of WINDOW_MONTHS months starting on `start_date`.
    def savings_rate(start_date)
      months = Array.new(WINDOW_MONTHS) do |i|
        month_start = start_date + i.months
        Period.custom(start_date: month_start, end_date: month_start + 1.month - 1.day)
      end

      incomes = months.map { |month| income_statement.income_totals(period: month).total.to_d }
      income = incomes.sort[WINDOW_MONTHS / 2] * WINDOW_MONTHS # the median: WINDOW_MONTHS is odd
      return nil if income <= 0

      expense = months.sum { |month| income_statement.expense_totals(period: month).total.to_d }
      (income - expense) / income * 100
    end
end
