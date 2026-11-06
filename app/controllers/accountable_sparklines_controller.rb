class AccountableSparklinesController < ApplicationController
  # Sparkline frames load lazily from the sidebar on every page and render no
  # layout: skip layout-only setup and never start an auto-sync from them.
  skip_before_action :sync_family, :set_default_chat, :restore_active_tabs, :detect_os

  def show
    @accountable = Accountable.from_type(params[:accountable_type]&.classify)
    sparkline = AccountableSparkline.new(@accountable)

    # A URL carrying the current version can't go stale, so the browser may reuse it.
    expires_in 1.day if params[:v] == sparkline.version

    # Use HTTP conditional GET so the client receives 304 Not Modified when possible.
    # The frame id is part of the response body, so it is part of the ETag.
    if stale?(etag: [ sparkline.cache_key, turbo_frame_request_id ], last_modified: Current.family.latest_sync_completed_at)
      @series = sparkline.series

      render layout: false
    end
  end
end
