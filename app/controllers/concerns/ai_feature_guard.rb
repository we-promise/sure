# One guard for controller actions that start an AI feature.
# It answers only "is this AI feature available for this family and user?", through the router:
#
#   requires_ai :bill_setup
#   requires_ai :enhance_merchants, only: :enhance
#
# Declare it after the domain's own guards (preview features, the recurring toggle), so the AI
# question only comes up when the feature itself is on.
module AiFeatureGuard
  extend ActiveSupport::Concern

  included do
    # feature => before_action options, read by test/architecture/ai_feature_guard_test.
    class_attribute :ai_requirements, instance_accessor: false, default: {}
  end

  class_methods do
    def requires_ai(feature, **options)
      self.ai_requirements = ai_requirements.merge(feature.to_sym => options)
      before_action(**options) { require_ai!(feature) }
    end
  end

  private
    def require_ai!(feature)
      availability = Ai.availability(feature, family: Current.family, user: Current.user)
      return if availability.available?

      respond_to do |format|
        format.html { redirect_back_or_to root_path, alert: availability.message_for(Current.user) }
        format.json { render json: { error: "ai_unavailable", reason: availability.reason }, status: :forbidden }
        format.any { head :forbidden }
      end
    end
end
