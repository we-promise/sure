# Compares the savings rate of the last three complete months with that of
# the three before, each from the window's summed income and spending. A
# monthly rate mostly measures which day the salary landed: paid on the 29th
# instead of the 1st, one month gets two salaries and the next none. A paycheck
# that moves between two months of the same window changes nothing here. One
# that crosses a window edge still shifts a third of a window's income, so a
# single early payday can show up when it enters the current window and again
# as it crosses the edges three and six months later; filing paychecks under
# the income bill occurrence they settle would remove that. The current
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
    previous_window = Period.custom(start_date: window_start - WINDOW_MONTHS.months, end_date: window_start - 1.day)

    current_rate = savings_rate(window)
    previous_rate = savings_rate(previous_window)
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
        # whole month and the nightly run doesn't reopen a dismissal.
        metadata: {
          current_rate: round(current_rate, 1),
          previous_rate: round(previous_rate, 1)
        },
        period: window,
        dedup_key: "savings_rate_change:#{month_token(last_month.start_date)}"
      )
    ]
  end

  private
    # From the window's summed income and spending, not an average of monthly
    # rates: a month whose pay landed elsewhere would dominate the average.
    def savings_rate(period)
      income = income_statement.income_totals(period: period).total.to_d
      return nil if income <= 0

      expense = income_statement.expense_totals(period: period).total.to_d
      (income - expense) / income * 100
    end
end
