class RetirementController < ApplicationController
  include PreviewGateable

  before_action :require_preview_features!
  before_action :ensure_module_enabled!
  before_action :load_goal_retirement

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.retirement"), nil ]
    ]
  end

  private
    def ensure_module_enabled!
      return if Current.family.retirement_enabled?(Current.user)
      raise ActionController::RoutingError, "Not Found"
    end

    def load_goal_retirement
      @goal = Current.family.goals
                            .where(type: "Goal::Retirement", user_id: Current.user.id)
                            .first
    end
end
