# frozen_string_literal: true

class Api::V1::InsightsController < Api::V1::BaseController
  before_action :ensure_read_scope
  before_action :require_preview_features_for_api

  def index
    insights = current_resource_owner.family.insights.visible.ordered

    render json: {
      insights: insights.map { |insight| serialize(insight) }
    }
  end

  private
    def ensure_read_scope
      authorize_scope!(:read)
    end

    def require_preview_features_for_api
      return if current_resource_owner.preview_features_enabled?

      render_json(
        { error: "feature_disabled", message: "Preview features are not enabled for this user" },
        status: :forbidden
      )
    end

    def serialize(insight)
      {
        id: insight.id,
        type: insight.insight_type,
        title: insight.title,
        body: insight.body,
        priority: insight.priority,
        status: insight.status,
        generated_at: insight.generated_at&.iso8601
      }
    end
end
