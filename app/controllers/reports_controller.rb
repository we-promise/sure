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

    # Transactions breakdown
    @transactions = build_transactions_breakdown

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

  def export_transactions
    @period_type = params[:period_type]&.to_sym || :monthly
    @start_date = parse_date_param(:start_date) || default_start_date
    @end_date = parse_date_param(:end_date) || default_end_date
    @period = Period.custom(start_date: @start_date, end_date: @end_date)

    # Get all transactions (no pagination for export)
    @transactions = build_transactions_breakdown_for_export

    respond_to do |format|
      format.csv do
        csv_data = generate_transactions_csv
        send_data csv_data,
                  filename: "transactions_#{@start_date.strftime('%Y%m%d')}_to_#{@end_date.strftime('%Y%m%d')}.csv",
                  type: "text/csv"
      end

      format.xlsx do
        begin
          xlsx_data = generate_transactions_xlsx
          send_data xlsx_data,
                    filename: "transactions_#{@start_date.strftime('%Y%m%d')}_to_#{@end_date.strftime('%Y%m%d')}.xlsx",
                    type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        rescue LoadError, NameError
          flash[:error] = "Excel export requires the 'caxlsx' gem to be installed"
          redirect_to reports_path(period_type: @period_type, start_date: @start_date, end_date: @end_date)
        end
      end

      format.pdf do
        begin
          pdf_data = generate_transactions_pdf
          send_data pdf_data,
                    filename: "transactions_#{@start_date.strftime('%Y%m%d')}_to_#{@end_date.strftime('%Y%m%d')}.pdf",
                    type: "application/pdf"
        rescue LoadError, NameError
          flash[:error] = "PDF export requires the 'prawn' gem to be installed"
          redirect_to reports_path(period_type: @period_type, start_date: @start_date, end_date: @end_date)
        end
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

      # Totals are integers in cents - keep as cents for display
      {
        current: {
          income: @current_income_totals.total.to_f,
          expenses: @current_expense_totals.total.to_f,
          net: (@current_income_totals.total - @current_expense_totals.total).to_f
        },
        previous: {
          income: @previous_income_totals.total.to_f,
          expenses: @previous_expense_totals.total.to_f,
          net: (@previous_income_totals.total - @previous_expense_totals.total).to_f
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
      weekday_total = 0
      weekend_total = 0
      weekday_count = 0
      weekend_count = 0

      # Build query matching income_statement logic:
      # Expenses are transactions with positive amounts, regardless of category
      expense_transactions = Transaction
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: Current.family.id, status: [ "draft", "active" ] })
        .where(entries: { entryable_type: "Transaction", excluded: false, date: @period.date_range })
        .where(kind: [ "standard", "loan_payment" ])
        .where("entries.amount > 0") # Positive amount = expense (matching income_statement logic)

      # Sum up amounts by weekday vs weekend
      expense_transactions.each do |transaction|
        entry = transaction.entry
        amount = entry.amount.to_f.to_i.abs

        if entry.date.wday.in?([ 0, 6 ]) # Sunday or Saturday
          weekend_total += amount
          weekend_count += 1
        else
          weekday_total += amount
          weekday_count += 1
        end
      end

      weekday_avg = weekday_count.positive? ? (weekday_total / weekday_count) : 0
      weekend_avg = weekend_count.positive? ? (weekend_total / weekend_count) : 0

      {
        weekday_total: weekday_total,
        weekend_total: weekend_total,
        weekday_avg: weekday_avg,
        weekend_avg: weekend_avg,
        weekday_count: weekday_count,
        weekend_count: weekend_count
      }
    end

    def default_spending_patterns
      {
        weekday_total: 0,
        weekend_total: 0,
        weekday_avg: 0,
        weekend_avg: 0,
        weekday_count: 0,
        weekend_count: 0
      }
    end

    def build_transactions_breakdown
      # Base query: all transactions in the period
      transactions = Transaction
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: Current.family.id, status: [ "draft", "active" ] })
        .where(entries: { entryable_type: "Transaction", excluded: false, date: @period.date_range })
        .includes(entry: :account, category: [])

      # Apply filters
      transactions = apply_transaction_filters(transactions)

      # Apply sorting
      sort_by = params[:sort_by] || "date"
      sort_direction = params[:sort_direction] || "desc"

      case sort_by
      when "date"
        transactions = transactions.order("entries.date #{sort_direction}")
      when "amount"
        transactions = transactions.order("entries.amount #{sort_direction}")
      else
        transactions = transactions.order("entries.date desc")
      end

      # Group by category and type
      all_transactions = transactions.to_a
      grouped_data = {}

      all_transactions.each do |transaction|
        entry = transaction.entry
        is_expense = entry.amount > 0
        type = is_expense ? "expense" : "income"
        category_name = transaction.category&.name || "Uncategorized"
        category_color = transaction.category&.color || "#9CA3AF"

        key = [ category_name, type, category_color ]
        grouped_data[key] ||= { total: 0, count: 0 }
        grouped_data[key][:count] += 1
        grouped_data[key][:total] += entry.amount.abs
      end

      # Convert to array and sort by total (descending)
      grouped_data.map do |key, data|
        {
          category_name: key[0],
          type: key[1],
          category_color: key[2],
          total: data[:total],
          count: data[:count]
        }
      end.sort_by { |g| -g[:total] }
    end

    def apply_transaction_filters(transactions)
      # Filter by category
      if params[:filter_category_id].present?
        transactions = transactions.where(category_id: params[:filter_category_id])
      end

      # Filter by account
      if params[:filter_account_id].present?
        transactions = transactions.where(entries: { account_id: params[:filter_account_id] })
      end

      # Filter by tag
      if params[:filter_tag_id].present?
        transactions = transactions.joins(:taggings).where(taggings: { tag_id: params[:filter_tag_id] })
      end

      # Filter by amount range
      if params[:filter_amount_min].present?
        transactions = transactions.where("ABS(entries.amount) >= ?", params[:filter_amount_min].to_f)
      end

      if params[:filter_amount_max].present?
        transactions = transactions.where("ABS(entries.amount) <= ?", params[:filter_amount_max].to_f)
      end

      # Filter by date range (within the period)
      if params[:filter_date_start].present?
        filter_start = Date.parse(params[:filter_date_start])
        transactions = transactions.where("entries.date >= ?", filter_start) if filter_start >= @start_date
      end

      if params[:filter_date_end].present?
        filter_end = Date.parse(params[:filter_date_end])
        transactions = transactions.where("entries.date <= ?", filter_end) if filter_end <= @end_date
      end

      transactions
    rescue Date::Error
      transactions
    end

    def build_transactions_breakdown_for_export
      # Get flat transactions list (not grouped) for export
      transactions = Transaction
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: Current.family.id, status: [ "draft", "active" ] })
        .where(entries: { entryable_type: "Transaction", excluded: false, date: @period.date_range })
        .includes(entry: :account, category: [])

      transactions = apply_transaction_filters(transactions)

      sort_by = params[:sort_by] || "date"
      sort_direction = params[:sort_direction] || "desc"

      case sort_by
      when "date"
        transactions.order("entries.date #{sort_direction}")
      when "amount"
        transactions.order("entries.amount #{sort_direction}")
      else
        transactions.order("entries.date desc")
      end
    end

    def generate_transactions_csv
      require "csv"

      CSV.generate do |csv|
        # Header row
        csv << [ "Date", "Category", "Type", "Amount" ]

        # Data rows
        @transactions.each do |transaction|
          entry = transaction.entry
          is_expense = entry.amount > 0

          csv << [
            entry.date.strftime("%Y-%m-%d"),
            transaction.category&.name || "Uncategorized",
            is_expense ? "Expense" : "Income",
            Money.new(entry.amount.abs, entry.currency).format
          ]
        end
      end
    end

    def generate_transactions_xlsx
      require "caxlsx"

      package = Axlsx::Package.new
      workbook = package.workbook

      workbook.add_worksheet(name: "Transactions") do |sheet|
        # Header row
        sheet.add_row [ "Date", "Category", "Type", "Amount" ],
                      style: workbook.styles.add_style(b: true)

        # Data rows
        @transactions.each do |transaction|
          entry = transaction.entry
          is_expense = entry.amount > 0

          sheet.add_row [
            entry.date.strftime("%Y-%m-%d"),
            transaction.category&.name || "Uncategorized",
            is_expense ? "Expense" : "Income",
            Money.new(entry.amount.abs, entry.currency).format
          ]
        end
      end

      package.to_stream.read
    end

    def generate_transactions_pdf
      require "prawn"

      Prawn::Document.new do |pdf|
        pdf.text "Transaction Report", size: 20, style: :bold
        pdf.text "Period: #{@start_date.strftime('%b %-d, %Y')} to #{@end_date.strftime('%b %-d, %Y')}", size: 12
        pdf.move_down 20

        if @transactions.any?
          table_data = [ [ "Date", "Category", "Type", "Amount" ] ]

          @transactions.each do |transaction|
            entry = transaction.entry
            is_expense = entry.amount > 0

            table_data << [
              entry.date.strftime("%Y-%m-%d"),
              transaction.category&.name || "Uncategorized",
              is_expense ? "Expense" : "Income",
              Money.new(entry.amount.abs, entry.currency).format
            ]
          end

          pdf.table(table_data, header: true, width: pdf.bounds.width) do
            row(0).font_style = :bold
            row(0).background_color = "EEEEEE"
            columns(0..2).align = :left
            columns(3).align = :right
            self.row_colors = [ "FFFFFF", "F9F9F9" ]
            self.header = true
          end
        else
          pdf.text "No transactions found for this period.", size: 12
        end
      end.render
    end

    def generate_csv_export(income_totals, expense_totals, period)
      require "csv"

      CSV.generate do |csv|
        # Header
        csv << [ "Reports Export" ]
        csv << [ "Period", "#{period.date_range.first} to #{period.date_range.last}" ]
        csv << []

        # Summary
        total_income = ensure_money(income_totals.total)
        total_expenses = ensure_money(expense_totals.total)
        net_savings = total_income - total_expenses

        csv << [ "Summary" ]
        csv << [ "Total Income", total_income.format ]
        csv << [ "Total Expenses", total_expenses.format ]
        csv << [ "Net Savings", net_savings.format ]
        csv << []

        # Income breakdown
        csv << [ "Income by Category" ]
        csv << [ "Category", "Amount", "Percentage" ]
        income_totals.category_totals.each do |ct|
          csv << [ ct.category.name, ensure_money(ct.total).format, "#{ct.weight.round(1)}%" ]
        end
        csv << []

        # Expense breakdown
        csv << [ "Expenses by Category" ]
        csv << [ "Category", "Amount", "Percentage" ]
        expense_totals.category_totals.each do |ct|
          csv << [ ct.category.name, ensure_money(ct.total).format, "#{ct.weight.round(1)}%" ]
        end
      end
    end
end
