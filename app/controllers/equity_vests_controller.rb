class EquityVestsController < ApplicationController
  MAX_SCHEDULED_VESTS = 120

  before_action :set_grant, only: %i[create]

  # Adds one vest, or a repeating schedule when `every_months` and `count` are given.
  def create
    vest_dates = schedule_dates
    if vest_dates.empty?
      return redirect_to account_path(@grant.account, tab: "grants"), alert: t(".invalid")
    end

    EquityVest.transaction do
      vest_dates.each do |date|
        @grant.vests.find_or_initialize_by(vest_date: date).update!(
          units: vest_params[:units],
          units_withheld: vest_params[:units_withheld].presence,
          net_proceeds: vest_params[:net_proceeds].presence,
          source: "manual"
        )
      end
    end
    redirect_to account_path(@grant.account, tab: "grants"), notice: t(".created", count: vest_dates.size)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to account_path(@grant.account, tab: "grants"), alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    vest = EquityVest.joins(:equity_grant).where(equity_grants: { account_id: Current.user.accessible_accounts.select(:id) }).find(params[:id])
    account = vest.equity_grant.account
    return unless require_account_permission!(account)

    vest.destroy!
    redirect_to account_path(account, tab: "grants"), notice: t(".deleted")
  end

  private
    def set_grant
      @grant = EquityGrant.where(account_id: Current.user.accessible_accounts.select(:id)).find(params[:equity_grant_id])
      require_account_permission!(@grant.account)
    end

    def vest_params
      params.require(:equity_vest).permit(:vest_date, :units, :units_withheld, :net_proceeds, :every_months, :count)
    end

    def schedule_dates
      first = Date.iso8601(vest_params[:vest_date].to_s)
      every = vest_params[:every_months].to_i
      count = vest_params[:count].to_i
      return [ first ] if every <= 0 || count <= 1

      Array.new([ count, MAX_SCHEDULED_VESTS ].min) { |i| first >> (every * i) }
    rescue ArgumentError
      []
    end
end
