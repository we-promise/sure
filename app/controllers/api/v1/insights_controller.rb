# frozen_string_literal: true

class Api::V1::InsightsController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :index
  before_action -> { authorize_scope!(:write) }, only: :acknowledge
  before_action :reject_guest_writes!, only: :acknowledge
  before_action :require_preview_features_for_api

  def index
    insights = current_resource_owner.family.insights.visible.ordered

    render json: {
      insights: insights.map { |insight| serialize(insight) }
    }
  end

  def acknowledge
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

    insight = current_resource_owner.family.insights.about_shared_accounts.find(params[:id])
    insight.with_lock do
      # Account access can change while this request waits for the row lock.
      raise ActiveRecord::RecordNotFound unless current_resource_owner.family.insights.about_shared_accounts.exists?(id: insight.id)

      # Replays must not overwrite timestamps or revive expired insights.
      if insight.active? || insight.read?
        insight.mark_read!
        insight.acknowledge!
      end
    end
    head :no_content
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
