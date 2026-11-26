class Api::V1::CashFlowsController < Api::V1::BaseController
  SANKEY = %w[sankey].freeze
  INVALID_RANGE = "Date ranges require view=sankey, both ISO dates in order, and no month".freeze
  INVALID_MONTH = "month must be a non-future ISO first day (YYYY-MM-01)".freeze

  before_action -> { authorize_scope!(:read) }

  def show
    response.headers["Cache-Control"] = "private, no-store"
    today = Date.current
    statement = IncomeStatement.new(current_resource_owner.family, user: current_resource_owner)
    # Sending include with view, or group_by without view, is refused before
    # the values are read, whatever they are.
    raise QueryError.new("invalid_view", "include and view cannot be combined") unless params[:include].nil? || params[:view].nil?
    include_mode, view = reading_as("invalid_view", "include and view support only sankey") do
      [ enum_filter_param(:include, SANKEY), enum_filter_param(:view, SANKEY) ]
    end

    raise QueryError.new("invalid_group_by", "group_by requires view=sankey") unless params[:group_by].nil? || view
    group_by = reading_as("invalid_group_by", "group_by must be category or account") do
      enum_filter_param(:group_by, IncomeStatement::CashFlowGraph::GROUPINGS.keys)
    end

    start_date, end_date = reading_as("invalid_period", INVALID_RANGE) do
      [ date_filter_param(:start_date), date_filter_param(:end_date) ]
    end
    if start_date || end_date
      unless view && params[:month].nil? && start_date && end_date && start_date <= end_date
        raise QueryError.new("invalid_period", INVALID_RANGE)
      end
      period = Period.custom(start_date: start_date, end_date: end_date)
    else
      month = reading_as("invalid_month", INVALID_MONTH) { date_filter_param(:month) } || today.beginning_of_month
      raise QueryError.new("invalid_month", INVALID_MONTH) unless month.day == 1 && month <= today

      period = Period.custom(start_date: month, end_date: [ month.end_of_month, today ].min)
    end

    if view
      # Arbitrary graph ranges must not allocate a daily comparison series.
      render json: IncomeStatement::CashFlowGraph.new(statement, period: period, group_by: group_by || "category", as_of: today)
    else
      render json: IncomeStatement::CashFlow.new(statement, month: month, as_of: today, include_sankey: include_mode.present?)
    end
  end
end
