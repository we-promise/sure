class ReportsController < ApplicationController
  include Periodable

  # Allow API key authentication for exports (for Google Sheets integration)
  # Note: We run authentication_for_export which handles both session and API key auth
  skip_authentication only: :export_transactions
  before_action :authenticate_for_export, only: :export_transactions

  def index
    @period_type = params[:period_type]&.to_sym || :monthly
    @start_date = parse_date_param(:start_date) || default_start_date
    @end_date = parse_date_param(:end_date) || default_end_date

    # Validate and fix date range if end_date is before start_date
    validate_and_fix_date_range(show_flash: true)

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

    # Build trend data (last 6 months)
    @trends_data = build_trends_data

    # Spending patterns (weekday vs weekend)
    @spending_patterns = build_spending_patterns

    # Transactions breakdown
    @transactions = build_transactions_breakdown

    @breadcrumbs = [ [ "Home", root_path ], [ "Reports", nil ] ]
  end

  def export_transactions
    @period_type = params[:period_type]&.to_sym || :monthly
    @start_date = parse_date_param(:start_date) || default_start_date
    @end_date = parse_date_param(:end_date) || default_end_date

    # Validate and fix date range if end_date is before start_date
    # Don't show flash message since we're returning CSV data
    validate_and_fix_date_range(show_flash: false)

    @period = Period.custom(start_date: @start_date, end_date: @end_date)

    # Build monthly breakdown data for export
    @export_data = build_monthly_breakdown_for_export

    respond_to do |format|
      format.csv do
        csv_data = generate_transactions_csv
        send_data csv_data,
                  filename: "transactions_breakdown_#{@start_date.strftime('%Y%m%d')}_to_#{@end_date.strftime('%Y%m%d')}.csv",
                  type: "text/csv"
      end

      # Excel and PDF exports require additional gems (caxlsx and prawn)
      # Uncomment and install gems if needed:
      #
      # format.xlsx do
      #   xlsx_data = generate_transactions_xlsx
      #   send_data xlsx_data,
      #             filename: "transactions_breakdown_#{@start_date.strftime('%Y%m%d')}_to_#{@end_date.strftime('%Y%m%d')}.xlsx",
      #             type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      # end
      #
      # format.pdf do
      #   pdf_data = generate_transactions_pdf
      #   send_data pdf_data,
      #             filename: "transactions_breakdown_#{@start_date.strftime('%Y%m%d')}_to_#{@end_date.strftime('%Y%m%d')}.pdf",
      #             type: "application/pdf"
      # end
    end
  end

  def google_sheets_instructions
    # Re-build the params needed for the export URL
    base_params = {
      period_type: params[:period_type],
      start_date: params[:start_date],
      end_date: params[:end_date],
      sort_by: params[:sort_by],
      sort_direction: params[:sort_direction]
    }.compact

    # Build the full URL with the API key, if present
    @csv_url = export_transactions_reports_url(base_params.merge(format: :csv))
    @api_key_present = @csv_url.include?("api_key=")

    # This action will render `app/views/reports/google_sheets_instructions.html.erb`
    # It will render *inside* the modal frame.
  end

  private

    def validate_and_fix_date_range(show_flash: false)
      return unless @start_date > @end_date

      # Swap the dates to maintain user's intended date range
      @start_date, @end_date = @end_date, @start_date
      flash.now[:alert] = t("reports.invalid_date_range") if show_flash
    end

    def ensure_money(value)
      return value if value.is_a?(Money)
      # Value is numeric (BigDecimal or Integer) in dollars - pass directly to Money.new
      Money.new(value, Current.family.currency)
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
      when :last_6_months
        6.months.ago.beginning_of_month.to_date
      when :custom
        1.month.ago.to_date
      else
        Date.current.beginning_of_month.to_date
      end
    end

    def default_end_date
      case @period_type
      when :monthly, :last_6_months
        Date.current.end_of_month.to_date
      when :quarterly
        Date.current.end_of_quarter.to_date
      when :ytd
        Date.current
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

    def build_trends_data
      # Generate month-by-month data based on the current period filter
      trends = []

      # Generate list of months within the period
      current_month = @start_date.beginning_of_month
      end_of_period = @end_date.end_of_month

      while current_month <= end_of_period
        month_start = current_month
        month_end = current_month.end_of_month

        # Ensure we don't go beyond the end date
        month_end = @end_date if month_end > @end_date

        period = Period.custom(start_date: month_start, end_date: month_end)

        income = Current.family.income_statement.income_totals(period: period).total
        expenses = Current.family.income_statement.expense_totals(period: period).total

        trends << {
          month: month_start.strftime("%b %Y"),
          income: income,
          expenses: expenses,
          net: income - expenses
        }

        current_month = current_month.next_month
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
        amount = entry.amount.abs

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
      # Exclude transfers, one-time, and CC payments (matching income_statement logic)
      transactions = Transaction
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: Current.family.id, status: [ "draft", "active" ] })
        .where(entries: { entryable_type: "Transaction", excluded: false, date: @period.date_range })
        .where.not(kind: [ "funds_movement", "one_time", "cc_payment" ])
        .includes(entry: :account, category: [])

      # Apply filters
      transactions = apply_transaction_filters(transactions)

      # Get sort parameters
      sort_by = params[:sort_by] || "amount"
      sort_direction = params[:sort_direction] || "desc"

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

      # Convert to array
      result = grouped_data.map do |key, data|
        {
          category_name: key[0],
          type: key[1],
          category_color: key[2],
          total: data[:total],
          count: data[:count]
        }
      end

      # Sort by amount (total) with the specified direction
      if sort_direction == "asc"
        result.sort_by { |g| g[:total] }
      else
        result.sort_by { |g| -g[:total] }
      end
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
      # Exclude transfers, one-time, and CC payments (matching income_statement logic)
      transactions = Transaction
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: Current.family.id, status: [ "draft", "active" ] })
        .where(entries: { entryable_type: "Transaction", excluded: false, date: @period.date_range })
        .where.not(kind: [ "funds_movement", "one_time", "cc_payment" ])
        .includes(entry: :account, category: [])

      transactions = apply_transaction_filters(transactions)

      sort_by = params[:sort_by] || "date"
      # Whitelist sort_direction to prevent SQL injection
      sort_direction = %w[asc desc].include?(params[:sort_direction]&.downcase) ? params[:sort_direction].upcase : "DESC"

      case sort_by
      when "date"
        transactions.order("entries.date #{sort_direction}")
      when "amount"
        transactions.order("entries.amount #{sort_direction}")
      else
        transactions.order("entries.date DESC")
      end
    end

    def build_monthly_breakdown_for_export
      # Generate list of months in the period
      months = []
      current_month = @start_date.beginning_of_month
      end_of_period = @end_date.end_of_month

      while current_month <= end_of_period
        months << current_month
        current_month = current_month.next_month
      end

      # Get all transactions in the period
      # Exclude transfers, one-time, and CC payments (matching income_statement logic)
      transactions = Transaction
        .joins(:entry)
        .joins(entry: :account)
        .where(accounts: { family_id: Current.family.id, status: [ "draft", "active" ] })
        .where(entries: { entryable_type: "Transaction", excluded: false, date: @period.date_range })
        .where.not(kind: [ "funds_movement", "one_time", "cc_payment" ])
        .includes(entry: :account, category: [])

      transactions = apply_transaction_filters(transactions)

      # Group transactions by category, type, and month
      breakdown = {}

      transactions.each do |transaction|
        entry = transaction.entry
        is_expense = entry.amount > 0
        type = is_expense ? "expense" : "income"
        category_name = transaction.category&.name || "Uncategorized"
        month_key = entry.date.beginning_of_month

        key = [ category_name, type ]
        breakdown[key] ||= { category: category_name, type: type, months: {}, total: 0 }
        breakdown[key][:months][month_key] ||= 0
        breakdown[key][:months][month_key] += entry.amount.abs
        breakdown[key][:total] += entry.amount.abs
      end

      # Convert to array and sort by type and total (descending)
      result = breakdown.map do |key, data|
        {
          category: data[:category],
          type: data[:type],
          months: data[:months],
          total: data[:total]
        }
      end

      # Separate and sort income and expenses
      income_data = result.select { |r| r[:type] == "income" }.sort_by { |r| -r[:total] }
      expense_data = result.select { |r| r[:type] == "expense" }.sort_by { |r| -r[:total] }

      {
        months: months,
        income: income_data,
        expenses: expense_data
      }
    end

    def generate_transactions_csv
      require "csv"

      CSV.generate do |csv|
        # Build header row: Category + Month columns + Total
        month_headers = @export_data[:months].map { |m| m.strftime("%b %Y") }
        header_row = [ "Category" ] + month_headers + [ "Total" ]
        csv << header_row

        # Income section
        if @export_data[:income].any?
          csv << [ "INCOME" ] + Array.new(month_headers.length + 1, "")

          @export_data[:income].each do |category_data|
            row = [ category_data[:category] ]

            # Add amounts for each month
            @export_data[:months].each do |month|
              amount = category_data[:months][month] || 0
              row << Money.new(amount, Current.family.currency).format
            end

            # Add row total
            row << Money.new(category_data[:total], Current.family.currency).format
            csv << row
          end

          # Income totals row
          totals_row = [ "TOTAL INCOME" ]
          @export_data[:months].each do |month|
            month_total = @export_data[:income].sum { |c| c[:months][month] || 0 }
            totals_row << Money.new(month_total, Current.family.currency).format
          end
          grand_income_total = @export_data[:income].sum { |c| c[:total] }
          totals_row << Money.new(grand_income_total, Current.family.currency).format
          csv << totals_row

          # Blank row
          csv << []
        end

        # Expenses section
        if @export_data[:expenses].any?
          csv << [ "EXPENSES" ] + Array.new(month_headers.length + 1, "")

          @export_data[:expenses].each do |category_data|
            row = [ category_data[:category] ]

            # Add amounts for each month
            @export_data[:months].each do |month|
              amount = category_data[:months][month] || 0
              row << Money.new(amount, Current.family.currency).format
            end

            # Add row total
            row << Money.new(category_data[:total], Current.family.currency).format
            csv << row
          end

          # Expenses totals row
          totals_row = [ "TOTAL EXPENSES" ]
          @export_data[:months].each do |month|
            month_total = @export_data[:expenses].sum { |c| c[:months][month] || 0 }
            totals_row << Money.new(month_total, Current.family.currency).format
          end
          grand_expenses_total = @export_data[:expenses].sum { |c| c[:total] }
          totals_row << Money.new(grand_expenses_total, Current.family.currency).format
          csv << totals_row
        end
      end
    end

    def generate_transactions_xlsx
      require "caxlsx"

      package = Axlsx::Package.new
      workbook = package.workbook
      bold_style = workbook.styles.add_style(b: true)

      workbook.add_worksheet(name: "Breakdown") do |sheet|
        # Build header row: Category + Month columns + Total
        month_headers = @export_data[:months].map { |m| m.strftime("%b %Y") }
        header_row = [ "Category" ] + month_headers + [ "Total" ]
        sheet.add_row header_row, style: bold_style

        # Income section
        if @export_data[:income].any?
          sheet.add_row [ "INCOME" ] + Array.new(month_headers.length + 1, ""), style: bold_style

          @export_data[:income].each do |category_data|
            row = [ category_data[:category] ]

            # Add amounts for each month
            @export_data[:months].each do |month|
              amount = category_data[:months][month] || 0
              row << Money.new(amount, Current.family.currency).format
            end

            # Add row total
            row << Money.new(category_data[:total], Current.family.currency).format
            sheet.add_row row
          end

          # Income totals row
          totals_row = [ "TOTAL INCOME" ]
          @export_data[:months].each do |month|
            month_total = @export_data[:income].sum { |c| c[:months][month] || 0 }
            totals_row << Money.new(month_total, Current.family.currency).format
          end
          grand_income_total = @export_data[:income].sum { |c| c[:total] }
          totals_row << Money.new(grand_income_total, Current.family.currency).format
          sheet.add_row totals_row, style: bold_style

          # Blank row
          sheet.add_row []
        end

        # Expenses section
        if @export_data[:expenses].any?
          sheet.add_row [ "EXPENSES" ] + Array.new(month_headers.length + 1, ""), style: bold_style

          @export_data[:expenses].each do |category_data|
            row = [ category_data[:category] ]

            # Add amounts for each month
            @export_data[:months].each do |month|
              amount = category_data[:months][month] || 0
              row << Money.new(amount, Current.family.currency).format
            end

            # Add row total
            row << Money.new(category_data[:total], Current.family.currency).format
            sheet.add_row row
          end

          # Expenses totals row
          totals_row = [ "TOTAL EXPENSES" ]
          @export_data[:months].each do |month|
            month_total = @export_data[:expenses].sum { |c| c[:months][month] || 0 }
            totals_row << Money.new(month_total, Current.family.currency).format
          end
          grand_expenses_total = @export_data[:expenses].sum { |c| c[:total] }
          totals_row << Money.new(grand_expenses_total, Current.family.currency).format
          sheet.add_row totals_row, style: bold_style
        end
      end

      package.to_stream.read
    end

    def generate_transactions_pdf
      require "prawn"

      Prawn::Document.new(page_layout: :landscape) do |pdf|
        pdf.text "Transaction Breakdown Report", size: 20, style: :bold
        pdf.text "Period: #{@start_date.strftime('%b %-d, %Y')} to #{@end_date.strftime('%b %-d, %Y')}", size: 12
        pdf.move_down 20

        if @export_data[:income].any? || @export_data[:expenses].any?
          # Build header row
          month_headers = @export_data[:months].map { |m| m.strftime("%b %Y") }
          header_row = [ "Category" ] + month_headers + [ "Total" ]

          # Income section
          if @export_data[:income].any?
            pdf.text "INCOME", size: 14, style: :bold
            pdf.move_down 10

            income_table_data = [ header_row ]

            @export_data[:income].each do |category_data|
              row = [ category_data[:category] ]

              @export_data[:months].each do |month|
                amount = category_data[:months][month] || 0
                row << Money.new(amount, Current.family.currency).format
              end

              row << Money.new(category_data[:total], Current.family.currency).format
              income_table_data << row
            end

            # Income totals row
            totals_row = [ "TOTAL INCOME" ]
            @export_data[:months].each do |month|
              month_total = @export_data[:income].sum { |c| c[:months][month] || 0 }
              totals_row << Money.new(month_total, Current.family.currency).format
            end
            grand_income_total = @export_data[:income].sum { |c| c[:total] }
            totals_row << Money.new(grand_income_total, Current.family.currency).format
            income_table_data << totals_row

            pdf.table(income_table_data, header: true, width: pdf.bounds.width, cell_style: { size: 8 }) do
              row(0).font_style = :bold
              row(0).background_color = "CCFFCC"
              row(-1).font_style = :bold
              row(-1).background_color = "99FF99"
              columns(0).align = :left
              columns(1..-1).align = :right
              self.row_colors = [ "FFFFFF", "F9F9F9" ]
            end

            pdf.move_down 20
          end

          # Expenses section
          if @export_data[:expenses].any?
            pdf.text "EXPENSES", size: 14, style: :bold
            pdf.move_down 10

            expenses_table_data = [ header_row ]

            @export_data[:expenses].each do |category_data|
              row = [ category_data[:category] ]

              @export_data[:months].each do |month|
                amount = category_data[:months][month] || 0
                row << Money.new(amount, Current.family.currency).format
              end

              row << Money.new(category_data[:total], Current.family.currency).format
              expenses_table_data << row
            end

            # Expenses totals row
            totals_row = [ "TOTAL EXPENSES" ]
            @export_data[:months].each do |month|
              month_total = @export_data[:expenses].sum { |c| c[:months][month] || 0 }
              totals_row << Money.new(month_total, Current.family.currency).format
            end
            grand_expenses_total = @export_data[:expenses].sum { |c| c[:total] }
            totals_row << Money.new(grand_expenses_total, Current.family.currency).format
            expenses_table_data << totals_row

            pdf.table(expenses_table_data, header: true, width: pdf.bounds.width, cell_style: { size: 8 }) do
              row(0).font_style = :bold
              row(0).background_color = "FFCCCC"
              row(-1).font_style = :bold
              row(-1).background_color = "FF9999"
              columns(0).align = :left
              columns(1..-1).align = :right
              self.row_colors = [ "FFFFFF", "F9F9F9" ]
            end
          end
        else
          pdf.text "No transactions found for this period.", size: 12
        end
      end.render
    end

    # Export Authentication - handles both session and API key auth
    def authenticate_for_export
      if api_key_present?
        # Use API key authentication
        authenticate_with_api_key
      else
        # Use normal session authentication
        authenticate_user!
      end
    end

    # API Key Authentication Methods
    def api_key_present?
      params[:api_key].present? || request.headers["X-Api-Key"].present?
    end

    def authenticate_with_api_key
      api_key_value = params[:api_key] || request.headers["X-Api-Key"]

      unless api_key_value
        render plain: "API key is required", status: :unauthorized
        return false
      end

      @api_key = ApiKey.find_by_value(api_key_value)

      unless @api_key && @api_key.active?
        render plain: "Invalid or expired API key", status: :unauthorized
        return false
      end

      # Check if API key has read permissions
      unless @api_key.scopes&.include?("read") || @api_key.scopes&.include?("read_write")
        render plain: "API key does not have read permission", status: :forbidden
        return false
      end

      # Set up the current user and session context
      @current_user = @api_key.user
      @api_key.update_last_used!

      # Set up Current context for API requests (similar to Api::V1::BaseController)
      # Return false if setup fails to halt the filter chain
      return false unless setup_current_context_for_api_key

      true
    end

    def setup_current_context_for_api_key
      unless @current_user
        render plain: "User not found for API key", status: :internal_server_error
        return false
      end

      # Find or create a session for this API request
      # We need to find or create a persisted session so that Current.user delegation works properly
      session = @current_user.sessions.first_or_create!(
        user_agent: request.user_agent,
        ip_address: request.ip
      )

      Current.session = session

      # Verify the delegation chain works
      unless Current.user
        render plain: "Failed to establish user context", status: :internal_server_error
        return false
      end

      # Ensure we have a valid family context
      unless Current.family
        render plain: "User does not have an associated family", status: :internal_server_error
        return false
      end

      true
    end
end
