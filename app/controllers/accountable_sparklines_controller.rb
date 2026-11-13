class AccountableSparklinesController < ApplicationController
  def show
    @accountable = Accountable.from_type(params[:accountable_type]&.classify)
    sparkline = AccountableSparkline.new(@accountable)

    # A URL carrying the current version can't go stale, so the browser may reuse it.
    expires_in 1.day if params[:v] == sparkline.version

    # Use HTTP conditional GET so the client receives 304 Not Modified when possible.
    if stale?(etag: sparkline.cache_key, last_modified: Current.family.latest_sync_completed_at)
      @series = sparkline.series

      render layout: false
    end
  end
end
