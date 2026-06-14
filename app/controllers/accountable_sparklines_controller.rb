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
      @family ||= Current.family
    end

    def account_scope
      @account_scope ||= family.accounts.visible.where(accountable_type: @accountable.name)
    end

    def account_ids
      @account_ids ||= account_identity_rows.map(&:first).uniq
    end

    def account_identity_rows
      @account_identity_rows ||= account_scope
        .left_outer_joins(:account_providers)
        .pluck(:id, :plaid_account_id, :simplefin_account_id, Arel.sql("account_providers.id"))
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

    # balance_type is derived purely from accountable_type, so only Investment/Crypto
    # can yield :investment. Short-circuit to avoid an N+1 `account.linked?` check
    # on every account for non-investment accountable types (loan, credit_card, etc).
    # The `Account.linked` scope is the SQL-level mirror of `Account#linked?`.
    def requires_normalized_aggregation?
      return false unless %w[Investment Crypto].include?(@accountable.name)

      account_identity_rows.any? do |_account_id, plaid_account_id, simplefin_account_id, account_provider_id|
        plaid_account_id.present? || simplefin_account_id.present? || account_provider_id.present?
      end
    end

    def aggregate_normalized_series
      Balance::LinkedInvestmentSeriesNormalizer.aggregate_account_ids(
        account_ids: account_ids,
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
