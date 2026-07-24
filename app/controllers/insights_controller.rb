class InsightsController < ApplicationController
  before_action :require_preview_features!
  before_action :set_insight, only: %i[dismiss undismiss]

  def index
    load_feed
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("insights.index.title"), nil ] ]

    # Viewing the feed is what "read" means here; the New badge for this
    # render comes from @unread_ids captured above. Turbo's hover prefetch
    # hits this GET before the user actually navigates, so skip the write
    # for prefetch requests or badges would clear on hover.
    unless prefetch_request?
      Current.family.insights.active.update_all(status: "read", read_at: Time.current, updated_at: Time.current)
    end
  end

  def dismiss
    @insight.dismiss!

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_back_or_to insights_path }
    end
  end

  def undismiss
    @insight.undismiss!
    load_feed

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_back_or_to insights_path }
    end
  end

  def refresh
    GenerateInsightsJob.perform_later(family_id: Current.family.id)

    respond_to do |format|
      # Swaps the button into its pending state; the job broadcasts the
      # refreshed list and the idle button back when it finishes.
      format.turbo_stream
      format.html { redirect_to insights_path, notice: t("insights.refresh.queued") }
    end
  end

  private
    def set_insight
      @insight = Current.family.insights.find(params[:id])
    end

    def load_feed
      @insights = Current.family.insights.visible.ordered.to_a
      @unread_ids = @insights.select(&:active?).map(&:id).to_set
    end

    # Turbo sends X-Sec-Purpose (the fetch spec forbids setting Sec-Purpose
    # from JS) on hover-prefetch requests.
    def prefetch_request?
      request.headers["X-Sec-Purpose"] == "prefetch" || request.headers["Sec-Purpose"].to_s.include?("prefetch")
    end
end
