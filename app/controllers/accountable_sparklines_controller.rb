class AccountableSparklinesController < ApplicationController
  # Renders the sparkline chart for a given accountable type
  def show
    @accountable = accountable

    if @accountable.nil?
      param_key = params[:accountable_type]&.underscore || "accountable"
      render html: helpers.turbo_frame_tag("#{param_key}_sparkline")
      return
    end

    # Don't render if there are no visible accounts for this type.
    if account_ids.empty?
      render html: helpers.turbo_frame_tag("#{@accountable.model_name.param_key}_sparkline")
      return
    end

    etag_key = cache_key

    # Use HTTP conditional GET so the client receives 304 Not Modified when possible.
    if stale?(etag: etag_key, last_modified: family.latest_sync_completed_at)
      @series = Rails.cache.fetch(etag_key, expires_in: 24.hours) do
        builder = Balance::ChartSeriesBuilder.new(
          account_ids: account_ids,
          currency: family.currency,
          period: Period.last_30_days,
          favorable_direction: @accountable.favorable_direction,
          interval: "1 day"
        )

        builder.balance_series
      end

      render layout: false
    end
  end

  private
    # Returns the current user's family
    def family
      Current.family
    end

    # Resolves the accountable model type from the request params
    def accountable
      @accountable ||= Accountable.from_type(params[:accountable_type]&.classify)
    end

    # Returns IDs of visible accounts for the current accountable type
    def account_ids
      @account_ids ||= family.accounts.visible.where(accountable_type: accountable.name).pluck(:id)
    end

    # Builds a cache key for the sparkline data, invalidated on data updates
    def cache_key
      family.build_cache_key("#{accountable.name}_sparkline", invalidate_on_data_updates: true)
    end
end
