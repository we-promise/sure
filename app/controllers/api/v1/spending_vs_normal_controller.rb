# Net spending per category for a period against each category's normal (the
# year before, scaled to the period): the data behind the Reports section
# "Spending vs normal".
class Api::V1::SpendingVsNormalController < Api::V1::BaseController
  before_action -> { authorize_scope!(:read) }

  def show
    response.headers["Cache-Control"] = "private, no-store"
    period = requested_period
    unless period
      return render json: { error: "invalid_period", message: "Pass both start_date and end_date as ISO dates in order, or neither for the current month" },
        status: :unprocessable_entity
    end

    statement = IncomeStatement.new(current_resource_owner.family, user: current_resource_owner)
    render json: IncomeStatement::SpendingComparison.new(
      statement,
      period: period,
      history_start: IncomeStatement::SpendingComparison.history_start(statement)
    )
  end

  private
    def requested_period
      # The whole current month; the comparison cuts an unfinished period to
      # today and compares it with the same days of earlier months.
      if params[:start_date].nil? && params[:end_date].nil?
        today = Date.current
        return Period.custom(start_date: today.beginning_of_month, end_date: today.end_of_month)
      end

      start_date, end_date = parse_date(params[:start_date]), parse_date(params[:end_date])
      Period.custom(start_date: start_date, end_date: end_date) if start_date && end_date && start_date <= end_date
    end
end
