class AccountsController < ApplicationController
  before_action :set_account, only: %i[sync sparkline toggle_active show destroy unlink confirm_unlink select_provider]
  include Periodable

  def index
    @manual_accounts = family.accounts
          .listable_manual
          .order(:name)
    @plaid_items = family.plaid_items.ordered.includes(:syncs, :plaid_accounts)
    @simplefin_items = family.simplefin_items.ordered.includes(:syncs)
    @lunchflow_items = family.lunchflow_items.ordered.includes(:syncs, :lunchflow_accounts)
    @enable_banking_items = family.enable_banking_items.ordered.includes(:syncs)
    @coinstats_items = family.coinstats_items.ordered.includes(:coinstats_accounts, :accounts, :syncs)
    @mercury_items = family.mercury_items.ordered.includes(:syncs, :mercury_accounts)
    @coinbase_items = family.coinbase_items.ordered.includes(:coinbase_accounts, :accounts, :syncs)
    @snaptrade_items = family.snaptrade_items.ordered.includes(:syncs, :snaptrade_accounts)
    @indexa_capital_items = family.indexa_capital_items.ordered.includes(:syncs, :indexa_capital_accounts)

    # Build sync stats maps for all providers
    build_sync_stats_maps

    # Prevent Turbo Drive from caching this page to ensure fresh account lists
    expires_now
    render layout: "settings"
  end

  def new
    # Get all registered providers with any credentials configured
    @provider_configs = Provider::Factory.registered_adapters.flat_map do |adapter_class|
      adapter_class.connection_configs(family: family)
    end
  end

  def sync_all
    family.sync_later
    redirect_to accounts_path, notice: t("accounts.sync_all.syncing")
  end

  def show
    @chart_view = params[:chart_view] || "balance"
    @tab = params[:tab]
    @q = params.fetch(:q, {}).permit(:search, status: [])
    entries = @account.entries.where(excluded: false).search(@q).reverse_chronological

    @pagy, @entries = pagy(entries, limit: safe_per_page)

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
        # Detach holdings from provider links before destroying them
        provider_link_ids = @account.account_providers.pluck(:id)
        if provider_link_ids.any?
          Holding.where(account_provider_id: provider_link_ids).update_all(account_provider_id: nil)
        end

        # Capture provider accounts before clearing links (so we can destroy them)
        simplefin_account_to_destroy = @account.simplefin_account

        # Remove new system links (account_providers join table)
        # SnaptradeAccount records are preserved (not destroyed) so users can relink later.
        # This follows the Plaid pattern where the provider account survives as "unlinked".
        # SnapTrade has limited connection slots (5 free), so preserving the record avoids
        # wasting a slot on reconnect.
        @account.account_providers.destroy_all

        # Remove legacy system links (foreign keys)
        @account.update!(plaid_account_id: nil, simplefin_account_id: nil)

        # Destroy the SimplefinAccount record so it doesn't cause stale account issues
        # This is safe because:
        # - Account data (transactions, holdings, balances) lives on the Account, not SimplefinAccount
        # - SimplefinAccount only caches API data which is regenerated on reconnect
        # - If user reconnects SimpleFin later, a new SimplefinAccount will be created
        simplefin_account_to_destroy&.destroy!
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

    account_type_name = @account.accountable_type

    # Get all available provider configs dynamically for this account type
    provider_configs = Provider::Factory.connection_configs_for_account_type(
      account_type: account_type_name,
      family: family
    )

    # Build available providers list with paths resolved for this specific account
    # Filter out providers that don't support linking to existing accounts
    @available_providers = provider_configs.filter_map do |config|
      next unless config[:existing_account_path].present?
      {
        name: config[:name],
        key: config[:key],
        description: config[:description],
        path: config[:existing_account_path].call(@account.id)
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

    # Builds sync stats maps for all provider types to avoid N+1 queries in views
    def build_sync_stats_maps
      # SimpleFIN sync stats
      @simplefin_sync_stats_map = {}
      @simplefin_has_unlinked_map = {}
      @simplefin_unlinked_count_map = {}
      @simplefin_show_relink_map = {}
      @simplefin_duplicate_only_map = {}

      @simplefin_items.each do |item|
        latest_sync = item.syncs.ordered.first
        stats = latest_sync&.sync_stats || {}
        @simplefin_sync_stats_map[item.id] = stats
        @simplefin_has_unlinked_map[item.id] = item.family.accounts.listable_manual.exists?

        # Count unlinked accounts
        count = item.simplefin_accounts
          .left_joins(:account, :account_provider)
          .where(accounts: { id: nil }, account_providers: { id: nil })
          .count
        @simplefin_unlinked_count_map[item.id] = count

        # CTA visibility
        manuals_exist = @simplefin_has_unlinked_map[item.id]
        sfa_any = item.simplefin_accounts.loaded? ? item.simplefin_accounts.any? : item.simplefin_accounts.exists?
        @simplefin_show_relink_map[item.id] = (count.to_i == 0 && manuals_exist && sfa_any)

        # Check if all errors are duplicate-skips
        errors = Array(stats["errors"]).map { |e| e.is_a?(Hash) ? e["message"] || e[:message] : e.to_s }
        @simplefin_duplicate_only_map[item.id] = errors.present? && errors.all? { |m| m.to_s.downcase.include?("duplicate upstream account detected") }
      rescue => e
        Rails.logger.warn("SimpleFin stats map build failed for item #{item.id}: #{e.class} - #{e.message}")
        @simplefin_sync_stats_map[item.id] = {}
        @simplefin_show_relink_map[item.id] = false
        @simplefin_duplicate_only_map[item.id] = false
      end

      # Plaid sync stats
      @plaid_sync_stats_map = {}
      @plaid_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @plaid_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Lunchflow sync stats
      @lunchflow_sync_stats_map = {}
      @lunchflow_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @lunchflow_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Enable Banking sync stats
      @enable_banking_sync_stats_map = {}
      @enable_banking_latest_sync_error_map = {}
      @enable_banking_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @enable_banking_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
        @enable_banking_latest_sync_error_map[item.id] = latest_sync&.error
      end

      # CoinStats sync stats
      @coinstats_sync_stats_map = {}
      @coinstats_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @coinstats_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Mercury sync stats
      @mercury_sync_stats_map = {}
      @mercury_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @mercury_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Coinbase sync stats
      @coinbase_sync_stats_map = {}
      @coinbase_unlinked_count_map = {}
      @coinbase_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @coinbase_sync_stats_map[item.id] = latest_sync&.sync_stats || {}

        # Count unlinked accounts
        count = item.coinbase_accounts
          .left_joins(:account_provider)
          .where(account_providers: { id: nil })
          .count
        @coinbase_unlinked_count_map[item.id] = count
      end

      # IndexaCapital sync stats
      @indexa_capital_sync_stats_map = {}
      @indexa_capital_items.each do |item|
        latest_sync = item.syncs.ordered.first
        @indexa_capital_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end
    end
end
