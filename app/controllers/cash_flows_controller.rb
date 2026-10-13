class CashFlowsController < ApplicationController
  before_action :require_preview_features!

  def show
    response.headers["Cache-Control"] = "private, no-store"
    start_date, end_date = parse_date(params[:start_date]), parse_date(params[:end_date])
    unless start_date && end_date && start_date <= end_date
      return render json: { error: "invalid_period" }, status: :unprocessable_entity
    end

    statement = IncomeStatement.new(Current.family, user: Current.user)
    period = Period.custom(start_date: start_date, end_date: end_date)
    # Resolve reporting dates after ordinary session authentication has set Current.
    Time.use_zone(resolved_timezone) do
      render json: IncomeStatement::CashFlowGraph.new(statement, period: period)
    end
  end

  private
    def parse_date(value)
      return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      date = Date.iso8601(value)
      date if date.year.positive?
    rescue Date::Error
      nil
    end
end
