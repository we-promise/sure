class TinkoffInvestItemsController < ApplicationController
  before_action :set_tinkoff_invest_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :create, :select_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def create
    @tinkoff_invest_item = Current.family.tinkoff_invest_items.build(tinkoff_invest_item_params)
    @tinkoff_invest_item.name ||= t("tinkoff_invest_items.defaults.name")

    if @tinkoff_invest_item.save
      @tinkoff_invest_item.sync_later

      redirect_to accounts_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("tinkoff_invest", alert: @tinkoff_invest_item.errors.full_messages.join(", "))
    end
  end

  def update
    attrs = tinkoff_invest_item_params.to_h
    attrs["api_key"] = @tinkoff_invest_item.api_key if attrs["api_key"].blank?

    if @tinkoff_invest_item.update(attrs.merge(status: :good))
      @tinkoff_invest_item.sync_later unless @tinkoff_invest_item.syncing?

      render_provider_panel("tinkoff_invest", notice: t(".success"), fallback_path: accounts_path)
    else
      render_provider_panel("tinkoff_invest", alert: @tinkoff_invest_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @tinkoff_invest_item.unlink_all!(dry_run: false)
    @tinkoff_invest_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @tinkoff_invest_item.sync_later unless @tinkoff_invest_item.syncing?
    return render_provider_panel("tinkoff_invest", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    item = current_tinkoff_invest_item
    unless item
      frame_redirect_to settings_providers_path, alert: t(".not_configured")
      return
    end

    redirect_to setup_accounts_tinkoff_invest_item_path(item)
  end

  def select_existing_account
    @account = linkable_accounts.find(params[:account_id])
    @available_tinkoff_invest_accounts = Current.family.tinkoff_invest_items
      .active
      .includes(tinkoff_invest_accounts: { account_provider: :account })
      .flat_map(&:tinkoff_invest_accounts)
      .select { |tinkoff_account| tinkoff_account.account_provider.nil? }
      .sort_by { |tinkoff_account| tinkoff_account.updated_at || tinkoff_account.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    account = linkable_accounts.find_by(id: params[:account_id])
    tinkoff_account = TinkoffInvestAccount
      .joins(:tinkoff_invest_item)
      .where(tinkoff_invest_items: { family_id: Current.family.id })
      .find_by(id: params[:tinkoff_invest_account_id])

    if account.blank? || tinkoff_account.blank?
      redirect_to settings_providers_path, alert: t(".not_found")
      return
    end

    if account.accountable_type != "Investment" || account.account_providers.any? || account.plaid_account_id.present? || account.simplefin_account_id.present?
      redirect_to account_path(account), alert: t(".only_manual_investment")
      return
    end

    provider = nil

    tinkoff_account.with_lock do
      if tinkoff_account.current_account.present?
        redirect_to account_path(account), alert: t(".already_linked")
        return
      end

      provider = tinkoff_account.ensure_account_provider!(account)
    end

    raise "Failed to create AccountProvider link" unless provider

    enqueue_post_link_sync(tinkoff_account.tinkoff_invest_item)
    redirect_to account_path(account), notice: t(".success"), status: :see_other
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "Failed to link existing T-Invest account: #{e.class} - #{e.message}",
      source: "tinkoff_invest",
      family: Current.family,
      provider_key: "tinkoff_invest"
    )
    redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
  end

  def setup_accounts
    @tinkoff_invest_accounts = @tinkoff_invest_item.tinkoff_invest_accounts.includes(account_provider: :account).order(:name)
    @linked_accounts = @tinkoff_invest_accounts.select { |a| a.current_account.present? }
    @unlinked_accounts = @tinkoff_invest_accounts.reject { |a| a.current_account.present? }

    no_accounts = @linked_accounts.blank? && @unlinked_accounts.blank?
    latest_sync = @tinkoff_invest_item.syncs.ordered.first
    should_sync = latest_sync.nil? || !latest_sync.completed?

    if no_accounts && !@tinkoff_invest_item.syncing? && should_sync
      @tinkoff_invest_item.sync_later
    end

    @linkable_accounts = linkable_accounts
      .visible
      .where(accountable_type: "Investment")
      .where(plaid_account_id: nil, simplefin_account_id: nil)
      .left_joins(:account_providers)
      .where(account_providers: { id: nil })
      .order(:name)

    @syncing = @tinkoff_invest_item.syncing?
    @waiting_for_sync = no_accounts && @syncing
    @no_accounts_found = no_accounts && !@syncing && @tinkoff_invest_item.last_synced_at.present?
  end

  def complete_account_setup
    selected_accounts = Array(params[:account_ids]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |tinkoff_account_id|
      tinkoff_account = @tinkoff_invest_item.tinkoff_invest_accounts.find_by(id: tinkoff_account_id)
      next unless tinkoff_account

      tinkoff_account.with_lock do
        next if tinkoff_account.current_account.present?

        account = Account.create_from_tinkoff_invest_account(tinkoff_account)
        raise ActiveRecord::Rollback unless tinkoff_account.ensure_account_provider!(account)

        created_accounts << account
      end
    end

    @tinkoff_invest_item.update!(pending_account_setup: @tinkoff_invest_item.unlinked_accounts_count.positive?)
    enqueue_post_link_sync(@tinkoff_invest_item) if created_accounts.any?

    if created_accounts.any?
      redirect_to accounts_path, notice: t(".success", count: created_accounts.count), status: :see_other
    elsif selected_accounts.empty?
      redirect_to setup_accounts_tinkoff_invest_item_path(@tinkoff_invest_item), alert: t(".none_selected"), status: :see_other
    else
      redirect_to setup_accounts_tinkoff_invest_item_path(@tinkoff_invest_item), alert: t(".none_created"), status: :see_other
    end
  end

  private

    def set_tinkoff_invest_item
      @tinkoff_invest_item = Current.family.tinkoff_invest_items.find(params[:id])
    end

    def current_tinkoff_invest_item
      active_items = Current.family.tinkoff_invest_items.active
      active_items.syncable.ordered.first || active_items.ordered.first
    end

    def linkable_accounts
      Current.family.accounts.writable_by(Current.user)
    end

    def enqueue_post_link_sync(item = @tinkoff_invest_item)
      target = item || Current.family.tinkoff_invest_items.active.ordered.first
      return unless target

      target.sync_later unless target.syncing?
    end

    def tinkoff_invest_item_params
      params.require(:tinkoff_invest_item).permit(:name, :api_key, :environment, :base_url, :sync_start_date)
    end
end
