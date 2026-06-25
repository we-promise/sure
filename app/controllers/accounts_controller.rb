class AccountsController < ApplicationController
  include StreamExtensions

  before_action :set_account, only: %i[show sparkline sync set_default remove_default]
  before_action :set_manageable_account, only: %i[toggle_active destroy unlink confirm_unlink select_provider]
  include Periodable

  def index
    @accessible_account_ids = Current.user.accessible_accounts.pluck(:id)
    @manual_accounts = family.accounts
          .listable_manual
          .where(id: @accessible_account_ids)
          .with_attached_logo
          .includes(:accountable, :account_providers, :plaid_account, :simplefin_account)
          .order(:name)
    @plaid_items = visible_provider_items(family.plaid_items.ordered.with_attached_logo.includes(:plaid_accounts))
    @simplefin_items = visible_provider_items(family.simplefin_items.ordered.with_attached_logo)
    @lunchflow_items = visible_provider_items(family.lunchflow_items.ordered.with_attached_logo.includes(:lunchflow_accounts))
    @akahu_items = visible_provider_items(family.akahu_items.ordered.with_attached_logo.includes(:akahu_accounts))
    @up_items = visible_provider_items(family.up_items.ordered.with_attached_logo.includes(:up_accounts))
    @enable_banking_items = visible_provider_items(family.enable_banking_items.ordered.with_attached_logo)
    @coinstats_items = visible_provider_items(family.coinstats_items.ordered.with_attached_logo.includes(:coinstats_accounts, :accounts))
    @mercury_items = visible_provider_items(family.mercury_items.ordered.with_attached_logo.includes(:mercury_accounts))
    @brex_items = visible_provider_items(family.brex_items.ordered.with_attached_logo.includes(:accounts, brex_accounts: :account_provider))
    @coinbase_items = visible_provider_items(family.coinbase_items.ordered.with_attached_logo.includes(:coinbase_accounts, :accounts))
    @snaptrade_items = visible_provider_items(family.snaptrade_items.ordered.with_attached_logo.includes(:snaptrade_accounts))
    @ibkr_items = visible_provider_items(family.ibkr_items.ordered.with_attached_logo.includes(:ibkr_accounts))
    @indexa_capital_items = visible_provider_items(family.indexa_capital_items.ordered.with_attached_logo.includes(:indexa_capital_accounts))
    @sophtron_items = visible_provider_items(family.sophtron_items.ordered.with_attached_logo.includes(:sophtron_accounts))
    @binance_items = visible_provider_items(family.binance_items.ordered.with_attached_logo.includes(:binance_accounts, :accounts))

    preload_latest_sync_metadata_for_index!

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
    entries = @account.entries.where(excluded: false).search(@q).reverse_chronological.includes(:entryable)
    if statement_tab_active?
      build_statement_tab_data
      return render_statement_tab_frame if statement_tab_frame_request?
    end

    @pagy, @entries = pagy(
      entries,
      limit: safe_per_page,
      params: request.query_parameters.except("tab").merge("tab" => "activity")
    )
    Transaction::ActivitySecurityPreloader.new(@entries).preload

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
    etag_key = @account.family.build_cache_key("#{@account.id}_sparkline_#{Account::Chartable::SPARKLINE_CACHE_VERSION}", invalidate_on_data_updates: true)

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

  def set_default
    unless @account.eligible_for_transaction_default?
      redirect_to accounts_path, alert: t("accounts.set_default.depository_only")
      return
    end

    Current.user.update!(default_account: @account)
    redirect_to accounts_path
  end

  def remove_default
    Current.user.update!(default_account: nil)
    redirect_to accounts_path
  end

  def destroy
    if @account.linked?
      redirect_to account_path(@account), alert: t("accounts.destroy.cannot_delete_linked")
    else
      begin
        @account.destroy_later
        redirect_to accounts_path, notice: t("accounts.destroy.success", type: @account.accountable_type)
      rescue => e
        Rails.logger.error "Failed to schedule account #{@account.id} for deletion: #{e.message}"
        redirect_to accounts_path, alert: t("accounts.destroy.failed")
      end
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
      @account = Current.user.accessible_accounts.find(params[:id])
    end

    def set_manageable_account
      @account = Current.user.accessible_accounts.find(params[:id])
      permission = @account.permission_for(Current.user)
      unless permission.in?([ :owner, :full_control ])
        respond_to do |format|
          format.html { redirect_to account_path(@account), alert: t("accounts.not_authorized") }
          format.turbo_stream { stream_redirect_to(account_path(@account), alert: t("accounts.not_authorized")) }
        end
        nil
      end
    end

    def visible_provider_items(items)
      items.select do |item|
        Current.user.admin? ||
          (item.respond_to?(:accounts) && (item.accounts.map(&:id) & @accessible_account_ids).any?)
      end
    end

    def preload_latest_sync_metadata_for_index!
      items = [
        @plaid_items,
        @simplefin_items,
        @lunchflow_items,
        @akahu_items,
        @up_items,
        @enable_banking_items,
        @coinstats_items,
        @mercury_items,
        @brex_items,
        @coinbase_items,
        @snaptrade_items,
        @ibkr_items,
        @indexa_capital_items,
        @sophtron_items,
        @binance_items
      ].flatten.compact

      accounts = @manual_accounts.to_a
      items.each do |item|
        next unless item.respond_to?(:accounts)
        accounts.concat(item.accounts)
      end
      accounts = accounts.uniq { |account| account.id }

      syncables = items + accounts

      Current.latest_sync_by_syncable = Sync.latest_by_syncable(syncables)
      Current.latest_completed_sync_by_syncable = Sync.latest_completed_by_syncable(syncables)
      Current.syncing_by_syncable = Sync.syncing_by_syncable(syncables)
    end

    def build_statement_tab_data
      return unless statement_tab_active?

      @statement_coverage = AccountStatement::Coverage.for_year(@account, params[:statement_year])
      @account_statements = @account.account_statements.with_attached_original_file.ordered.to_a
      @statement_reconciliation_statuses = AccountStatement.reconciliation_statuses_for(@account_statements, account: @account)
      permission = @account.permission_for(Current.user)
      @can_manage_statements = AccountStatement.statement_manager?(Current.user) &&
        permission.in?([ :owner, :full_control ])
    end

    def statement_tab_frame_request?
      turbo_frame_request? && request.headers["Turbo-Frame"] == helpers.dom_id(@account, :statements_tab)
    end

    def render_statement_tab_frame
      render partial: "accounts/show/statements_frame", locals: statement_tab_locals, layout: false
    end

    def statement_tab_locals
      {
        account: @account,
        coverage: @statement_coverage,
        statements: @account_statements,
        reconciliation_statuses: @statement_reconciliation_statuses,
        can_manage_statements: @can_manage_statements
      }
    end

    def statement_tab_active?
      @tab == "statements"
    end

    # Builds sync stats maps for all provider types to avoid N+1 queries in views
    def build_sync_stats_maps
      manual_accounts_exist = @manual_accounts.any?

      # SimpleFIN sync stats
      @simplefin_sync_stats_map = {}
      @simplefin_has_unlinked_map = {}
      @simplefin_unlinked_count_map = {}
      @simplefin_show_relink_map = {}
      @simplefin_duplicate_only_map = {}

      simplefin_item_ids = @simplefin_items.map(&:id)
      simplefin_accounts_counts_by_item_id =
        if simplefin_item_ids.any?
          SimplefinAccount.where(simplefin_item_id: simplefin_item_ids).group(:simplefin_item_id).count
        else
          {}
        end
      simplefin_unlinked_counts_by_item_id =
        if simplefin_item_ids.any?
          SimplefinAccount.where(simplefin_item_id: simplefin_item_ids)
            .left_joins(:account, :account_provider)
            .where(accounts: { id: nil }, account_providers: { id: nil })
            .group(:simplefin_item_id)
            .count
        else
          {}
        end

      @simplefin_items.each do |item|
        latest_sync = item.latest_sync_record
        stats = latest_sync&.sync_stats || {}
        @simplefin_sync_stats_map[item.id] = stats
        @simplefin_has_unlinked_map[item.id] = manual_accounts_exist

        # Count unlinked accounts
        count = simplefin_unlinked_counts_by_item_id[item.id].to_i
        @simplefin_unlinked_count_map[item.id] = count

        # CTA visibility
        manuals_exist = @simplefin_has_unlinked_map[item.id]
        sfa_any = simplefin_accounts_counts_by_item_id[item.id].to_i > 0
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
        latest_sync = item.latest_sync_record
        @plaid_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Lunchflow sync stats
      @lunchflow_sync_stats_map = {}
      @lunchflow_items.each do |item|
        latest_sync = item.latest_sync_record
        @lunchflow_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Akahu sync stats
      @akahu_sync_stats_map = {}
      @akahu_items.each do |item|
        latest_sync = item.latest_sync_record
        @akahu_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Up sync stats
      @up_sync_stats_map = {}
      @up_items.each do |item|
        latest_sync = item.latest_sync_record
        @up_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Enable Banking sync stats
      @enable_banking_sync_stats_map = {}
      @enable_banking_latest_sync_error_map = {}
      @enable_banking_items.each do |item|
        latest_sync = item.latest_sync_record
        @enable_banking_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
        @enable_banking_latest_sync_error_map[item.id] = latest_sync&.error
      end

      # CoinStats sync stats
      @coinstats_sync_stats_map = {}
      @coinstats_items.each do |item|
        latest_sync = item.latest_sync_record
        @coinstats_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Sophtron sync stats
      @sophtron_sync_stats_map = {}
      @sophtron_items.each do |item|
        latest_sync = item.latest_sync_record
        @sophtron_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Mercury sync stats
      @mercury_sync_stats_map = {}
      @mercury_items.each do |item|
        latest_sync = item.latest_sync_record
        @mercury_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Brex sync stats
      @brex_sync_stats_map = {}
      @brex_account_counts_map = {}
      @brex_institutions_count_map = {}
      @brex_items.each do |item|
        latest_sync = item.latest_sync_record
        @brex_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
        brex_accounts = item.brex_accounts.to_a
        linked_count = brex_accounts.count { |brex_account| brex_account.account_provider.present? }
        total_count = brex_accounts.count
        @brex_account_counts_map[item.id] = {
          linked: linked_count,
          unlinked: total_count - linked_count,
          total: total_count
        }
        @brex_institutions_count_map[item.id] = brex_accounts
          .filter_map(&:institution_metadata)
          .uniq { |institution| institution["name"] || institution["institution_name"] }
          .count
      end

      # Coinbase sync stats
      @coinbase_sync_stats_map = {}
      @coinbase_unlinked_count_map = {}

      coinbase_item_ids = @coinbase_items.map(&:id)
      coinbase_unlinked_counts_by_item_id =
        if coinbase_item_ids.any?
          CoinbaseAccount.where(coinbase_item_id: coinbase_item_ids)
            .left_joins(:account_provider)
            .where(account_providers: { id: nil })
            .group(:coinbase_item_id)
            .count
        else
          {}
        end

      @coinbase_items.each do |item|
        latest_sync = item.latest_sync_record
        @coinbase_sync_stats_map[item.id] = latest_sync&.sync_stats || {}

        # Count unlinked accounts
        @coinbase_unlinked_count_map[item.id] = coinbase_unlinked_counts_by_item_id[item.id].to_i
      end

      # IndexaCapital sync stats
      @indexa_capital_sync_stats_map = {}
      @indexa_capital_items.each do |item|
        latest_sync = item.latest_sync_record
        @indexa_capital_sync_stats_map[item.id] = latest_sync&.sync_stats || {}
      end

      # Binance sync stats
      @binance_sync_stats_map = {}
      @binance_unlinked_count_map = {}
      @binance_items.each do |item|
        latest_sync = item.latest_sync_record
        @binance_sync_stats_map[item.id] = latest_sync&.sync_stats || {}

        # Count unlinked accounts
        count = item.binance_accounts
          .left_joins(:account_provider)
          .where(account_providers: { id: nil })
          .count
        @binance_unlinked_count_map[item.id] = count
      end
    end
end
