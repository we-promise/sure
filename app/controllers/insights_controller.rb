class InsightsController < ApplicationController
  include FeatureGuardable

  guard_feature unless: -> { Current.user.insights_enabled? }

  before_action :set_insight, only: %i[read dismiss]

  def index
    @insights = Current.family.insights
                  .visible
                  .ordered
  end

  def read
    @insight.mark_read!
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace(@insight, partial: "insights/insight_card", locals: { insight: @insight, compact: false }) }
      format.html { redirect_to insights_path }
    end
  end

  def dismiss
    @insight.dismiss!
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(@insight) }
      format.html { redirect_to insights_path }
    end
  end

  def refresh
    GenerateInsightsJob.perform_later(family_id: Current.family.id)
    redirect_to insights_path, notice: t("insights.refresh_queued")
  end

  private
    def set_insight
      @insight = Current.family.insights.find(params[:id])
    end
end
