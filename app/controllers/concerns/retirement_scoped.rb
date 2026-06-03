# Shared gate + plan loading for the Retirement surface and its nested
# resource controllers. Tier 1 (preview features) comes from
# PreviewGateable; tier 2 is the family killswitch. The plan is
# bootstrapped per owner so nested resources always have a parent.
module RetirementScoped
  extend ActiveSupport::Concern
  include PreviewGateable

  included do
    before_action :require_preview_features!
    before_action :ensure_retirement_enabled!
    before_action :load_retirement_plan
  end

  private
    def ensure_retirement_enabled!
      return if Current.family.retirement_enabled?(Current.user)
      # head :not_found rather than raising ActionController::RoutingError:
      # raising from a before_action renders the routing debug page in
      # development (consider_all_requests_local), which is misleading.
      head :not_found
    end

    def load_retirement_plan
      @plan = Goal::Retirement.for_owner(Current.user)
    end
end
