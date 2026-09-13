# A bounded monthly projection of Sure's existing reporting calculations.
# The client never needs to download transaction history to reproduce these rules.
class IncomeStatement::FinancialSummary
  def initialize(statement, month:, as_of: Date.current, time_zone: Time.zone.tzinfo.identifier)
    raise ArgumentError, "month must be a non-future first day" unless month.day == 1 && month <= as_of

    @statement = statement
    @month = month
    @as_of = as_of
    @time_zone = time_zone
  end

  def as_json(*)
    current_period = Period.custom(start_date: @month, end_date: [ @month.end_of_month, @as_of ].min)
    previous_month = @month.prev_month
    previous_period = Period.custom(start_date: previous_month, end_date: previous_month.end_of_month)
    totals = @statement.totals_for(current_period)
    income = totals.income_money.amount
    spending = totals.expense_money.amount
    current = cumulative_series(current_period)
    previous = cumulative_series(previous_period)
    comparison_day = @month == @as_of.beginning_of_month ? [ @as_of.day, previous.size ].min : previous.size
    previous_total = previous.fetch(comparison_day - 1).fetch(:amount).to_d
    current_total = current.last.fetch(:amount).to_d

    {
      month: @month.iso8601, as_of: @as_of.iso8601, time_zone: @time_zone,
      currency: @statement.family.currency,
      period: period_json(current_period), income: decimal(income), spending: decimal(spending),
      net_savings: decimal(income - spending),
      savings_rate: income.positive? ? decimal((income - spending) / income * 100) : nil,
      spending_comparison: {
        previous_period: period_json(previous_period),
        current_total: decimal(current_total), comparison_total: decimal(previous_total),
        comparison_end_date: previous.fetch(comparison_day - 1).fetch(:date),
        delta: decimal(current_total - previous_total), current: current, previous: previous
      }
    }
  end

  private
    def cumulative_series(period)
      daily = @statement.daily_expense_series(period: period).index_by(&:date)
      cumulative = BigDecimal("0")
      period.date_range.map do |date|
        cumulative += daily[date]&.total || 0
        { date: date.iso8601, amount: decimal(cumulative) }
      end
    end

    def period_json(period)
      { start_date: period.start_date.iso8601, end_date: period.end_date.iso8601 }
    end

    def decimal(value)
      value.to_d.to_s("F")
    end
end
