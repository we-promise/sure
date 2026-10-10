class Api::V1::MonthlySpendingsController < Api::V1::BaseController
  before_action -> { authorize_scope!(:read) }

  def show
    response.headers["Cache-Control"] = "private, no-store"
    unless current_resource_owner.preview_features_enabled?
      return render json: { error: "preview_required", message: "Enable preview features in Preferences" }, status: :forbidden
    end

    statement = IncomeStatement.new(current_resource_owner.family, user: current_resource_owner)
    render json: IncomeStatement::MonthlySpending.new(statement, params: params.to_unsafe_h.slice("from", "to", "account_ids", "category_ids").symbolize_keys)
  rescue IncomeStatement::MonthlySpending::InvalidSelection => error
    render json: { error: "invalid_selection", message: error.message }, status: :unprocessable_entity
  end
end
