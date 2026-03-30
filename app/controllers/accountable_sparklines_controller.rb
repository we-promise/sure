class AccountableSparklinesController < ApplicationController
  def show
    @accountable = Accountable.from_type(params[:accountable_type]&.classify)

    etag_key = cache_key

    # Use HTTP conditional GET so the client receives 304 Not Modified when possible.
    if stale?(etag: etag_key, last_modified: family.latest_sync_completed_at)
      @series = Rails.cache.fetch(etag_key, expires_in: 24.hours) do
        build_series
      end

      render layout: false
    end
  end

  private
    def family
      Current.family
    end

    def accountable
      Accountable.from_type(params[:accountable_type]&.classify)
    end

    def account_ids
      family.accounts.visible.where(accountable_type: accountable.name).pluck(:id)
    end

    def accounts
      @accounts ||= family.accounts.visible.where(accountable_type: accountable.name)
    end

    def build_series
      return aggregate_normalized_series if requires_normalized_aggregation?

      Balance::ChartSeriesBuilder.new(
        account_ids: account_ids,
        currency: family.currency,
        period: Period.last_30_days,
        favorable_direction: @accountable.favorable_direction,
        interval: "1 day"
      ).balance_series
    end

    def requires_normalized_aggregation?
      accounts.any? { |account| account.linked? && account.balance_type == :investment }
    end

    def aggregate_normalized_series
      Balance::LinkedInvestmentSeriesNormalizer.aggregate_accounts(
        accounts: accounts,
        currency: family.currency,
        period: Period.last_30_days,
        favorable_direction: @accountable.favorable_direction,
        interval: "1 day"
      )
    end

    def cache_key
      family.build_cache_key("#{@accountable.name}_sparkline_#{Account::Chartable::SPARKLINE_CACHE_VERSION}", invalidate_on_data_updates: true)
    end
end
