class ReportsController < ApplicationController
  include Periodable

  def index
    @period_type = params[:period_type]&.to_sym || :monthly
    @start_date = parse_date_param(:start_date) || default_start_date
    @end_date = parse_date_param(:end_date) || default_end_date

    # Build the period
    @period = Period.custom(start_date: @start_date, end_date: @end_date)
    @previous_period = build_previous_period

    # Get aggregated data
    @current_income_totals = Current.family.income_statement.income_totals(period: @period)
    @current_expense_totals = Current.family.income_statement.expense_totals(period: @period)

    @previous_income_totals = Current.family.income_statement.income_totals(period: @previous_period)
    @previous_expense_totals = Current.family.income_statement.expense_totals(period: @previous_period)

    # Calculate summary metrics
    @summary_metrics = build_summary_metrics

    # Build comparison data
    @comparison_data = build_comparison_data

    # Get budget performance data (for current month only)
    @budget_performance = build_budget_performance

    # Build trend data (last 6 months)
    @trends_data = build_trends_data

    # Spending patterns (weekday vs weekend)
    @spending_patterns = build_spending_patterns

    @breadcrumbs = [ [ "Home", root_path ], [ "Reports", nil ] ]
  end

  def export
    @period_type = params[:period_type]&.to_sym || :monthly
    @start_date = parse_date_param(:start_date) || default_start_date
    @end_date = parse_date_param(:end_date) || default_end_date

    period = Period.custom(start_date: @start_date, end_date: @end_date)
    income_totals = Current.family.income_statement.income_totals(period: period)
    expense_totals = Current.family.income_statement.expense_totals(period: period)

    respond_to do |format|
      format.csv do
        csv_data = generate_csv_export(income_totals, expense_totals, period)
        send_data csv_data,
                  filename: "reports_#{@period_type}_#{@start_date.strftime('%Y%m%d')}.csv",
                  type: "text/csv"
      end
    end
  end

  private

    def ensure_money(value)
      return value if value.is_a?(Money)
      # If value is numeric (like 0), it's already in fractional units (cents)
      Money.new(value.to_i, Current.family.currency)
    end

    def parse_date_param(param_name)
      date_string = params[param_name]
      return nil if date_string.blank?

      Date.parse(date_string)
    rescue Date::Error
      nil
    end

    def default_start_date
      case @period_type
      when :monthly
        Date.current.beginning_of_month.to_date
      when :quarterly
        Date.current.beginning_of_quarter.to_date
      when :ytd
        Date.current.beginning_of_year.to_date
      when :custom
        1.month.ago.to_date
      else
        Date.current.beginning_of_month.to_date
      end
    end

    def default_end_date
      case @period_type
      when :monthly, :quarterly, :ytd
        Date.current.end_of_month.to_date
      when :custom
        Date.current
      else
        Date.current.end_of_month.to_date
      end
    end

    def build_previous_period
      duration = (@end_date - @start_date).to_i
      previous_end = @start_date - 1.day
      previous_start = previous_end - duration.days

      Period.custom(start_date: previous_start, end_date: previous_end)
    end

    def build_summary_metrics
      # Ensure we always have Money objects
      current_income = ensure_money(@current_income_totals.total)
      current_expenses = ensure_money(@current_expense_totals.total)
      net_savings = current_income - current_expenses

      previous_income = ensure_money(@previous_income_totals.total)
      previous_expenses = ensure_money(@previous_expense_totals.total)

      # Calculate percentage changes
      income_change = calculate_percentage_change(previous_income, current_income)
      expense_change = calculate_percentage_change(previous_expenses, current_expenses)

      # Get budget performance for current period
      budget_percent = calculate_budget_performance

      {
        current_income: current_income,
        income_change: income_change,
        current_expenses: current_expenses,
        expense_change: expense_change,
        net_savings: net_savings,
        budget_percent: budget_percent
      }
    end

    def calculate_percentage_change(previous_value, current_value)
      return 0 if previous_value.zero?

      ((current_value - previous_value) / previous_value * 100).round(1)
    end

    def calculate_budget_performance
      # Only calculate if we're looking at current month
      return nil unless @period_type == :monthly && @start_date.beginning_of_month.to_date == Date.current.beginning_of_month.to_date

      budget = Budget.find_or_bootstrap(Current.family, start_date: @start_date.beginning_of_month.to_date)
      return 0 if budget.nil? || budget.allocated_spending.zero?

      (budget.actual_spending / budget.allocated_spending * 100).round(1)
    rescue StandardError
      nil
    end

    def build_comparison_data
      currency_symbol = Money::Currency.new(Current.family.currency).symbol

      {
        current: {
          income: (@current_income_totals.total.to_f / 100.0).round(2),
          expenses: (@current_expense_totals.total.to_f / 100.0).round(2),
          net: ((@current_income_totals.total - @current_expense_totals.total).to_f / 100.0).round(2)
        },
        previous: {
          income: (@previous_income_totals.total.to_f / 100.0).round(2),
          expenses: (@previous_expense_totals.total.to_f / 100.0).round(2),
          net: ((@previous_income_totals.total - @previous_expense_totals.total).to_f / 100.0).round(2)
        },
        currency_symbol: currency_symbol
      }
    end

    def build_budget_performance
      return [] unless @period_type == :monthly

      budget = Budget.find_or_bootstrap(Current.family, start_date: @start_date.beginning_of_month.to_date)
      return [] if budget.nil?

      budget.budget_categories.includes(:category).map do |bc|
        next if bc.category.nil?

        actual = bc.actual_spending
        budgeted = bc.budgeted_spending
        remaining = budgeted - actual
        percent_used = budgeted.zero? ? 0 : (actual / budgeted * 100).round(1)

        {
          category_id: bc.category.id,
          category_name: bc.category.name,
          category_color: bc.category.color || Category::UNCATEGORIZED_COLOR,
          budgeted: budgeted.to_f.to_i,
          actual: actual.to_f.to_i,
          remaining: remaining.to_f.to_i,
          percent_used: percent_used,
          status: budget_status(percent_used)
        }
      end.compact.sort_by { |b| -b[:percent_used] }
    end

    def budget_status(percent_used)
      if percent_used >= 100
        :over
      elsif percent_used >= 80
        :warning
      else
        :good
      end
    end

    def build_trends_data
      # Get last 6 months of data for trends
      trends = []
      6.downto(0) do |i|
        month_start = i.months.ago.beginning_of_month.to_date
        month_end = i.months.ago.end_of_month.to_date
        period = Period.custom(start_date: month_start, end_date: month_end)

        income = Current.family.income_statement.income_totals(period: period).total
        expenses = Current.family.income_statement.expense_totals(period: period).total

        trends << {
          month: month_start.strftime("%b %Y"),
          income: income.to_f.to_i,
          expenses: expenses.to_f.to_i,
          net: (income - expenses).to_f.to_i
        }
      end

      trends
    end

    def build_spending_patterns
      # Analyze weekday vs weekend spending
      # Get expense entries for the period
      entries = Entry.joins(:account)
        .where(accounts: { family_id: Current.family.id })
        .where(date: @period.date_range)
        .where(entryable_type: "Transaction")
        .includes(:entryable)
        .select { |e| e.entryable&.category&.classification == "expense" }

      weekday_total = Money.new(0, Current.family.currency)
      weekend_total = Money.new(0, Current.family.currency)
      weekday_count = 0
      weekend_count = 0

      entries.each do |entry|
        if entry.date.wday.in?([ 0, 6 ]) # Sunday or Saturday
          weekend_total += entry.amount.abs
          weekend_count += 1
        else
          weekday_total += entry.amount.abs
          weekday_count += 1
        end
      end

      weekday_avg = weekday_count.positive? ? weekday_total / weekday_count : Money.new(0, Current.family.currency)
      weekend_avg = weekend_count.positive? ? weekend_total / weekend_count : Money.new(0, Current.family.currency)

      {
        weekday_total: weekday_total.to_f.to_i,
        weekend_total: weekend_total.to_f.to_i,
        weekday_avg: weekday_avg.to_f.to_i,
        weekend_avg: weekend_avg.to_f.to_i,
        weekday_count: weekday_count,
        weekend_count: weekend_count
      }
    end

    def generate_csv_export(income_totals, expense_totals, period)
      require "csv"

      CSV.generate do |csv|
        # Header
        csv << [ "Reports Export" ]
        csv << [ "Period", "#{period.date_range.first} to #{period.date_range.last}" ]
        csv << []

        # Summary
        csv << [ "Summary" ]
        csv << [ "Total Income", income_totals.total.format ]
        csv << [ "Total Expenses", expense_totals.total.format ]
        csv << [ "Net Savings", (income_totals.total - expense_totals.total).format ]
        csv << []

        # Income breakdown
        csv << [ "Income by Category" ]
        csv << [ "Category", "Amount", "Percentage" ]
        income_totals.category_totals.each do |ct|
          csv << [ ct.category.name, ct.total.format, "#{ct.weight.round(1)}%" ]
        end
        csv << []

        # Expense breakdown
        csv << [ "Expenses by Category" ]
        csv << [ "Category", "Amount", "Percentage" ]
        expense_totals.category_totals.each do |ct|
          csv << [ ct.category.name, ct.total.format, "#{ct.weight.round(1)}%" ]
        end
      end
    end
end
