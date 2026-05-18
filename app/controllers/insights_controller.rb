class InsightsController < ApplicationController
  before_action :set_insight, only: %i[read dismiss]

  def index
    @insights = Current.family.insights.visible.by_priority
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("insights.index.title"), nil ] ]
  end

  def read
    @insight.mark_read!

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to insights_path }
    end
  end

  def dismiss
    @insight.dismiss!

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(@insight) }
      format.html { redirect_to insights_path, notice: t("insights.dismissed") }
    end
  end

  def refresh
    GenerateInsightsJob.perform_later(family_id: Current.family.id)

    respond_to do |format|
      format.html { redirect_to insights_path, notice: t("insights.refresh_enqueued") }
    end
  end

  private
    def set_insight
      @insight = Current.family.insights.find(params[:id])
    end
end
