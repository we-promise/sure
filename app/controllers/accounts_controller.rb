class AccountsController < ApplicationController
  before_action :set_account, only: %i[sync sparkline toggle_active show destroy unlink confirm_unlink select_provider]
  include Periodable

  def index
    @manual_accounts = family.accounts
          .listable_manual
          .order(:name)
    @plaid_items = family.plaid_items.ordered
    @simplefin_items = family.simplefin_items.ordered.includes(:syncs)
    @lunchflow_items = family.lunchflow_items.ordered

    # Precompute per-item maps to avoid queries in the view
    @simplefin_sync_stats_map = {}
    @simplefin_has_unlinked_map = {}

    @simplefin_items.each do |item|
      latest_sync = item.syncs.ordered.first
      @simplefin_sync_stats_map[item.id] = (latest_sync&.sync_stats || {})
      @simplefin_has_unlinked_map[item.id] = item.family.accounts
        .listable_manual
        .exists?
    end

    # Count of SimpleFin accounts that are not linked (no legacy account and no AccountProvider)
    @simplefin_unlinked_count_map = {}
    @simplefin_items.each do |item|
      count = item.simplefin_accounts
        .left_joins(:account, :account_provider)
        .where(accounts: { id: nil }, account_providers: { id: nil })
        .count
      @simplefin_unlinked_count_map[item.id] = count
    end

    # Compute CTA visibility map used by the simplefin_item partial
    @simplefin_show_relink_map = {}
    @simplefin_items.each do |item|
      begin
        unlinked_count = @simplefin_unlinked_count_map[item.id] || 0
        manuals_exist = @simplefin_has_unlinked_map[item.id]
        sfa_any = if item.simplefin_accounts.loaded?
          item.simplefin_accounts.any?
        else
          item.simplefin_accounts.exists?
        end
        @simplefin_show_relink_map[item.id] = (unlinked_count.to_i == 0 && manuals_exist && sfa_any)
      rescue => e
        Rails.logger.warn("SimpleFin card: CTA computation failed for item #{item.id}: #{e.class} - #{e.message}")
        @simplefin_show_relink_map[item.id] = false
      end
    end

    # Prevent Turbo Drive from caching this page to ensure fresh account lists
    expires_now
    render layout: "settings"
  end

  def new
    @show_lunchflow_link = family.can_connect_lunchflow?
  end

  def sync_all
    family.sync_later
    redirect_to accounts_path, notice: t("accounts.sync_all.syncing")
  end

  def show
    @chart_view = params[:chart_view] || "balance"
    @tab = params[:tab]
    @q = params.fetch(:q, {}).permit(:search)
    entries = @account.entries.search(@q).reverse_chronological

    @pagy, @entries = pagy(entries, limit: params[:per_page] || "10")

    @activity_feed_data = Account::ActivityFeedData.new(@account, @entries)
  end

  def sync
    unless @account.syncing?
      if @account.linked?
        # Sync all provider items for this account
        # Each provider item will trigger an account sync when complete
        @account.account_providers.each do |account_provider|
          item = account_provider.adapter&.item
          item&.sync_later if item && !item.syncing?
        end
      else
        # Manual accounts just need balance materialization
        @account.sync_later
      end
    end

    redirect_to account_path(@account)
  end

  def sparkline
    etag_key = @account.family.build_cache_key("#{@account.id}_sparkline", invalidate_on_data_updates: true)

    # Short-circuit with 304 Not Modified when the client already has the latest version.
    # We defer the expensive series computation until we know the content is stale.
    if stale?(etag: etag_key, last_modified: @account.family.latest_sync_completed_at)
      @sparkline_series = @account.sparkline_series
      render layout: false
    end
  end

  def toggle_active
    if @account.active?
      @account.disable!
    elsif @account.disabled?
      @account.enable!
    end
    redirect_to accounts_path
  end

  def destroy
    if @account.linked?
      redirect_to account_path(@account), alert: t("accounts.destroy.cannot_delete_linked")
    else
      @account.destroy_later
      redirect_to accounts_path, notice: t("accounts.destroy.success", type: @account.accountable_type)
    end
  end

  def confirm_unlink
    unless @account.linked?
      redirect_to account_path(@account), alert: t("accounts.unlink.not_linked")
    end
  end

  def unlink
    unless @account.linked?
      redirect_to account_path(@account), alert: t("accounts.unlink.not_linked")
      return
    end

    begin
      Account.transaction do
        # Remove new system links (account_providers join table)
        @account.account_providers.destroy_all

        # Remove legacy system links (foreign keys)
        @account.update!(plaid_account_id: nil, simplefin_account_id: nil)
      end

      redirect_to accounts_path, notice: t("accounts.unlink.success")
    rescue ActiveRecord::RecordInvalid => e
      redirect_to account_path(@account), alert: t("accounts.unlink.error", error: e.message)
    rescue StandardError => e
      Rails.logger.error "Failed to unlink account #{@account.id}: #{e.message}"
      redirect_to account_path(@account), alert: t("accounts.unlink.error", error: t("accounts.unlink.generic_error"))
    end
  end

  def select_provider
    if @account.linked?
      redirect_to account_path(@account), alert: t("accounts.select_provider.already_linked")
      return
    end

    @available_providers = []

    # Check SimpleFIN
    if family.can_connect_simplefin?
      @available_providers << {
        name: "SimpleFIN",
        key: "simplefin",
        description: "Connect to your bank via SimpleFIN",
        path: select_existing_account_simplefin_items_path(account_id: @account.id)
      }
    end

    # Check Plaid US
    if family.can_connect_plaid_us?
      @available_providers << {
        name: "Plaid",
        key: "plaid_us",
        description: "Connect to your US bank via Plaid",
        path: select_existing_account_plaid_items_path(account_id: @account.id, region: "us")
      }
    end

    # Check Plaid EU
    if family.can_connect_plaid_eu?
      @available_providers << {
        name: "Plaid (EU)",
        key: "plaid_eu",
        description: "Connect to your EU bank via Plaid",
        path: select_existing_account_plaid_items_path(account_id: @account.id, region: "eu")
      }
    end

    # Check Lunch Flow
    if family.can_connect_lunchflow?
      @available_providers << {
        name: "Lunch Flow",
        key: "lunchflow",
        description: "Connect to your bank via Lunch Flow",
        path: select_existing_account_lunchflow_items_path(account_id: @account.id)
      }
    end

    if @available_providers.empty?
      redirect_to account_path(@account), alert: t("accounts.select_provider.no_providers")
    end
  end

  private
    def family
      Current.family
    end

    def set_account
      @account = family.accounts.find(params[:id])
    end
end
