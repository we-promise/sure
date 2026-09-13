class Api::V1::FinancialSummariesController < Api::V1::BaseController
  before_action :ensure_read_scope

  def show
    # Apply the authenticated family's time zone after the authentication callback.
    Time.use_zone(resolved_timezone) do
      today = Date.current
      value = params[:month]
      month = value.nil? ? today.beginning_of_month : parse_month(value)
      unless month && month.day == 1 && month <= today
        render json: { error: "invalid_month", message: "month must be a non-future ISO first day (YYYY-MM-01)" }, status: :unprocessable_entity
        return
      end
      statement = IncomeStatement.new(current_resource_owner.family, user: current_resource_owner)
      render json: IncomeStatement::FinancialSummary.new(statement, month: month, as_of: today)
    end
  end

  private
    def ensure_read_scope
      authorize_scope!(:read)
    end

    def parse_month(value)
      return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-01\z/)
      Date.iso8601(value)
    rescue Date::Error
      nil
    end
end
