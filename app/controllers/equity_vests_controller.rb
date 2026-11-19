class EquityVestsController < ApplicationController
  MAX_SCHEDULED_VESTS = 120

  before_action :set_account, only: %i[create]

  # Adds one vest, or a repeating schedule when `every_months` and `count` are
  # given. Dates that already have a vest are skipped, so an imported vest's
  # withheld units and proceeds are never overwritten.
  def create
    grant = @account.equity_grants.find(vest_params[:equity_grant_id])
    dates = schedule_dates
    return redirect_to grants_tab_path, alert: t(".invalid") if dates.empty?

    existing = grant.vests.where(vest_date: dates).pluck(:vest_date).to_set
    new_dates = dates.reject { |date| existing.include?(date) }

    EquityVest.transaction do
      new_dates.each { |date| grant.vests.create!(vest_date: date, units: vest_params[:units], source: "manual") }
    end

    notice = t(".created", count: new_dates.size)
    notice += " " + t(".skipped", count: existing.size) if existing.any?
    redirect_to grants_tab_path, notice: notice
  rescue ActiveRecord::RecordInvalid => e
    redirect_to grants_tab_path, alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    vest = EquityVest.joins(:equity_grant).where(equity_grants: { account_id: Current.user.accessible_accounts.select(:id) }).find(params[:id])
    @account = vest.equity_grant.account
    return unless require_account_permission!(@account)

    vest.destroy!
    redirect_to grants_tab_path, notice: t(".deleted")
  end

  private
    def set_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
      require_account_permission!(@account)
    end

    def grants_tab_path
      account_path(@account, tab: EquityGrantsController::TAB)
    end

    def vest_params
      params.require(:equity_vest).permit(:equity_grant_id, :vest_date, :units, :every_months, :count)
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
