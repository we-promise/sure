class Api::V1::CashFlowsController < Api::V1::BaseController
  before_action -> { authorize_scope!(:read) }

  def show
    response.headers["Cache-Control"] = "private, no-store"
    today = Date.current
    statement = IncomeStatement.new(current_resource_owner.family, user: current_resource_owner)
    if params[:include] && params[:view]
      return invalid_query("invalid_view", "include and view cannot be combined")
    end
    unless [ nil, "sankey" ].include?(params[:include]) && [ nil, "sankey" ].include?(params[:view])
      return invalid_query("invalid_view", "include and view support only sankey")
    end
    if params[:start_date] || params[:end_date]
      start_date, end_date = parse_date(params[:start_date]), parse_date(params[:end_date])
      unless params[:view] == "sankey" && params[:month].nil? && start_date && end_date && start_date <= end_date
        return invalid_query("invalid_period", "Date ranges require view=sankey, both ISO dates in order, and no month")
      end
      period = Period.custom(start_date: start_date, end_date: end_date)
    else
      month = params[:month].nil? ? today.beginning_of_month : parse_date(params[:month])
      unless month && month.day == 1 && month <= today
        return invalid_query("invalid_month", "month must be a non-future ISO first day (YYYY-MM-01)")
      end
      period = Period.custom(start_date: month, end_date: [ month.end_of_month, today ].min)
    end

    if params[:view] == "sankey"
      # Arbitrary graph ranges must not allocate a daily comparison series.
      render json: IncomeStatement::CashFlowGraph.new(statement, period: period, as_of: today)
    else
      render json: IncomeStatement::CashFlow.new(statement, month: month, as_of: today, include_sankey: params[:include] == "sankey")
    end
  end

  private
    def invalid_query(error, message)
      render json: { error: error, message: message }, status: :unprocessable_entity
    end

    def parse_date(value)
      return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      date = Date.iso8601(value)
      date if date.year.positive?
    rescue Date::Error
      nil
    end
end
