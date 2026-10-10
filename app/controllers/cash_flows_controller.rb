class CashFlowsController < ApplicationController
  before_action :require_preview_features!, only: :show

  def show
    response.headers["Cache-Control"] = "private, no-store"
    return render_monthly_spending if params[:view] == "monthly_spending"
    start_date, end_date = parse_date(params[:start_date]), parse_date(params[:end_date])
    unless start_date && end_date && start_date <= end_date
      return render json: { error: "invalid_period" }, status: :unprocessable_entity
    end

    group_by = params[:group_by].presence || "category"
    unless IncomeStatement::CashFlowGraph::GROUPINGS.key?(group_by)
      return render json: { error: "invalid_group_by" }, status: :unprocessable_entity
    end

    statement = IncomeStatement.new(Current.family, user: Current.user)
    period = Period.custom(start_date: start_date, end_date: end_date)
    # Resolve reporting dates after ordinary session authentication has set Current.
    Time.use_zone(resolved_timezone) do
      render json: IncomeStatement::CashFlowGraph.new(statement, period: period, group_by: group_by)
    end
  end

  def update_filters
    return head :not_found unless preview_features_enabled?
    preferences = User::MonthlySpendingPreferences.new(Current.user)
    if params[:reset] == "true"
      preferences.reset
    else
      period = params[:monthly_spending_period] || "last_twelve"
      dates = User::MonthlySpendingPreferences.period_dates(period)
      raise IncomeStatement::MonthlySpending::InvalidSelection, "Unknown period" if dates.nil? && period != "custom"
      selection = User::MonthlySpendingPreferences.selection(params, dates: dates)
      spending = IncomeStatement::MonthlySpending.new(Current.family.income_statement, params: selection)
      preferences.save(spending, period: period)
    end
    redirect_to root_path(PagesController.dashboard_view_params(params).except("monthly_spending_from", "monthly_spending_to", "monthly_spending_period", "monthly_spending_account_ids", "monthly_spending_category_ids")), status: :see_other
  rescue IncomeStatement::MonthlySpending::InvalidSelection
    redirect_to root_path(PagesController.dashboard_view_params(params)), status: :see_other
  end

  private
    def render_monthly_spending
      Time.use_zone(resolved_timezone) do
        statement = IncomeStatement.new(Current.family, user: Current.user)
        begin
          spending = IncomeStatement::MonthlySpending.new(statement, params: User::MonthlySpendingPreferences.selection(params))
        rescue IncomeStatement::MonthlySpending::InvalidSelection
          filter_error = true
          spending = IncomeStatement::MonthlySpending.new(statement)
        end
        render partial: "pages/dashboard/monthly_spending", locals: {
          monthly_spending: spending, filter_error: filter_error,
          view_params: PagesController.dashboard_view_params(params)
        }
      end
    end

    def parse_date(value)
      return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      date = Date.iso8601(value)
      date if date.year.positive?
    rescue Date::Error
      nil
    end
end
