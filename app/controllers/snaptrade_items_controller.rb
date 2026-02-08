class SnaptradeItemsController < ApplicationController
  before_action :set_snaptrade_item, only: [ :show, :edit, :update, :destroy, :sync, :connect, :setup_accounts, :complete_account_setup, :connections, :delete_connection, :delete_orphaned_user ]

  def index
    @snaptrade_items = Current.family.snaptrade_items.ordered
  end

  def show
  end

  def new
    @snaptrade_item = Current.family.snaptrade_items.build
  end

  def edit
  end

  def create
    @snaptrade_item = Current.family.snaptrade_items.build(snaptrade_item_params)
    @snaptrade_item.name ||= t("snaptrade_items.default_name")

    if @snaptrade_item.save
      # Register user with SnapTrade after saving credentials
      begin
        @snaptrade_item.ensure_user_registered!
      rescue => e
        Rails.logger.error "SnapTrade user registration failed: #{e.message}"
        # Don't fail the whole operation - user can retry connection later
      end

      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured SnapTrade.")
        @snaptrade_items = Current.family.snaptrade_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "snaptrade-providers-panel",
            partial: "settings/providers/snaptrade_panel",
            locals: { snaptrade_items: @snaptrade_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @snaptrade_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "snaptrade-providers-panel",
          partial: "settings/providers/snaptrade_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @snaptrade_item.update(snaptrade_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated SnapTrade configuration.")
        @snaptrade_items = Current.family.snaptrade_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "snaptrade-providers-panel",
            partial: "settings/providers/snaptrade_panel",
            locals: { snaptrade_items: @snaptrade_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @snaptrade_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "snaptrade-providers-panel",
          partial: "settings/providers/snaptrade_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @snaptrade_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled SnapTrade connection for deletion.")
  end

  def sync
    unless @snaptrade_item.syncing?
      @snaptrade_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Redirect user to SnapTrade connection portal
  def connect
    @snaptrade_item.ensure_user_registered! unless @snaptrade_item.user_registered?

    redirect_url = callback_snaptrade_items_url(item_id: @snaptrade_item.id)
    portal_url = @snaptrade_item.connection_portal_url(redirect_url: redirect_url)
    redirect_to portal_url, allow_other_host: true
  rescue ActiveRecord::Encryption::Errors::Decryption => e
    Rails.logger.error "SnapTrade decryption error for item #{@snaptrade_item.id}: #{e.class} - #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    redirect_to settings_providers_path, alert: t(".decryption_failed")
  rescue => e
    Rails.logger.error "SnapTrade connection error: #{e.class} - #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    redirect_to settings_providers_path, alert: t(".connection_failed", message: e.message)
  end

  # Handle callback from SnapTrade after user connects brokerage
  def callback
    # SnapTrade redirects back after user connects their brokerage
    # The connection is already established - we just need to sync to get the accounts
    unless params[:item_id].present?
      redirect_to settings_providers_path, alert: t(".no_item")
      return
    end

    snaptrade_item = Current.family.snaptrade_items.find_by(id: params[:item_id])

    if snaptrade_item
      # Trigger a sync to fetch the newly connected accounts
      snaptrade_item.sync_later unless snaptrade_item.syncing?
      # Redirect to accounts page - user can click "accounts need setup" badge
      # when sync completes. This avoids the auto-refresh loop issues.
      redirect_to accounts_path, notice: t(".success")
    else
      redirect_to settings_providers_path, alert: t(".no_item")
    end
  end

  # Show available accounts for linking
  def setup_accounts
    @snaptrade_accounts = @snaptrade_item.snaptrade_accounts.includes(account_provider: :account)
    @linked_accounts = @snaptrade_accounts.select { |sa| sa.current_account.present? }
    @unlinked_accounts = @snaptrade_accounts.reject { |sa| sa.current_account.present? }

    no_accounts = @unlinked_accounts.blank? && @linked_accounts.blank?

    # If no accounts and not syncing, trigger a sync
    if no_accounts && !@snaptrade_item.syncing?
      @snaptrade_item.sync_later
    end

    # Existing unlinked, visible investment/crypto accounts that could be linked instead of creating duplicates
    @linkable_accounts = Current.family.accounts
      .visible
      .where(accountable_type: %w[Investment Crypto])
      .left_joins(:account_providers)
      .where(account_providers: { id: nil })
      .order(:name)

    # Determine view state
    @syncing = @snaptrade_item.syncing?
    @waiting_for_sync = no_accounts && @syncing
    @no_accounts_found = no_accounts && !@syncing && @snaptrade_item.last_synced_at.present?
  end

  # Link selected accounts to Sure
  def complete_account_setup
    Rails.logger.info "SnapTrade complete_account_setup - params: #{params.to_unsafe_h.inspect}"
    account_ids = params[:account_ids] || []
    sync_start_dates = params[:sync_start_dates] || {}
    Rails.logger.info "SnapTrade complete_account_setup - account_ids: #{account_ids.inspect}, sync_start_dates: #{sync_start_dates.inspect}"

    linked_count = 0
    errors = []

    account_ids.each do |snaptrade_account_id|
      snaptrade_account = @snaptrade_item.snaptrade_accounts.find_by(id: snaptrade_account_id)

      unless snaptrade_account
        Rails.logger.warn "SnapTrade complete_account_setup - snaptrade_account not found for id: #{snaptrade_account_id}"
        next
      end

      if snaptrade_account.current_account.present?
        Rails.logger.info "SnapTrade complete_account_setup - snaptrade_account #{snaptrade_account_id} already linked to account #{snaptrade_account.current_account.id}"
        next
      end

      begin
        # Save sync_start_date if provided
        if sync_start_dates[snaptrade_account_id].present?
          snaptrade_account.update!(sync_start_date: sync_start_dates[snaptrade_account_id])
        end

        Rails.logger.info "SnapTrade complete_account_setup - linking snaptrade_account #{snaptrade_account_id}"
        link_snaptrade_account(snaptrade_account)
        linked_count += 1
        Rails.logger.info "SnapTrade complete_account_setup - successfully linked snaptrade_account #{snaptrade_account_id}"
      rescue => e
        Rails.logger.error "Failed to link SnapTrade account #{snaptrade_account_id}: #{e.class} - #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
        errors << e.message
      end
    end

    Rails.logger.info "SnapTrade complete_account_setup - completed. linked_count: #{linked_count}, errors: #{errors.inspect}"

    if linked_count > 0
      # Trigger sync to process the newly linked accounts
      # Always queue the sync - if one is running, this will run after it finishes
      @snaptrade_item.sync_later

      if errors.any?
        # Partial success - some linked, some failed
        redirect_to accounts_path, notice: t(".partial_success", linked: linked_count, failed: errors.size,
                                              default: "Linked #{linked_count} account(s). #{errors.size} failed to link.")
      else
        redirect_to accounts_path, notice: t(".success", count: linked_count, default: "Successfully linked #{linked_count} account(s).")
      end
    else
      if errors.any?
        # All failed
        redirect_to setup_accounts_snaptrade_item_path(@snaptrade_item),
                    alert: t(".link_failed", default: "Failed to link accounts: %{errors}", errors: errors.first)
      else
        redirect_to setup_accounts_snaptrade_item_path(@snaptrade_item),
                    alert: t(".no_accounts", default: "No accounts were selected for linking.")
      end
    end
  end

  # Fetch connections list for Turbo Frame
  def connections
    data = build_connections_list
    render partial: "snaptrade_items/connections_list", layout: false, locals: {
      connections: data[:connections],
      orphaned_users: data[:orphaned_users],
      snaptrade_item: @snaptrade_item,
      error: @error
    }
  end

  # Delete a brokerage connection
  def delete_connection
    authorization_id = params[:authorization_id]

    if authorization_id.blank?
      redirect_to settings_providers_path, alert: t(".failed", message: t(".missing_authorization_id"))
      return
    end

    # Delete all local SnaptradeAccounts for this connection (triggers cleanup job)
    accounts_deleted = @snaptrade_item.snaptrade_accounts
      .where(snaptrade_authorization_id: authorization_id)
      .destroy_all
      .size

    # If no local accounts existed (orphan), delete directly from API
    api_deletion_failed = false
    if accounts_deleted == 0
      provider = @snaptrade_item.snaptrade_provider
      creds = @snaptrade_item.snaptrade_credentials

      if provider && creds&.dig(:user_id) && creds&.dig(:user_secret)
        provider.delete_connection(
          user_id: creds[:user_id],
          user_secret: creds[:user_secret],
          authorization_id: authorization_id
        )
      else
        Rails.logger.warn "SnapTrade: Cannot delete orphaned connection #{authorization_id} - missing credentials"
        api_deletion_failed = true
      end
    end

    respond_to do |format|
      if api_deletion_failed
        format.html { redirect_to settings_providers_path, alert: t(".api_deletion_failed") }
        format.turbo_stream do
          flash.now[:alert] = t(".api_deletion_failed")
          render turbo_stream: flash_notification_stream_items
        end
      else
        format.html { redirect_to settings_providers_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.remove("connection_#{authorization_id}") }
      end
    end
  rescue Provider::Snaptrade::ApiError => e
    respond_to do |format|
      format.html { redirect_to settings_providers_path, alert: t(".failed", message: e.message) }
      format.turbo_stream do
        flash.now[:alert] = t(".failed", message: e.message)
        render turbo_stream: flash_notification_stream_items
      end
    end
  end

  # Delete an orphaned SnapTrade user (and all their connections)
  def delete_orphaned_user
    user_id = params[:user_id]

    # Security: verify this is actually an orphaned user
    unless @snaptrade_item.orphaned_users.include?(user_id)
      respond_to do |format|
        format.html { redirect_to settings_providers_path, alert: t(".failed") }
        format.turbo_stream do
          flash.now[:alert] = t(".failed")
          render turbo_stream: flash_notification_stream_items
        end
      end
      return
    end

    if @snaptrade_item.delete_orphaned_user(user_id)
      respond_to do |format|
        format.html { redirect_to settings_providers_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.remove("orphaned_user_#{user_id.parameterize}") }
      end
    else
      respond_to do |format|
        format.html { redirect_to settings_providers_path, alert: t(".failed") }
        format.turbo_stream do
          flash.now[:alert] = t(".failed")
          render turbo_stream: flash_notification_stream_items
        end
      end
    end
  end

  # Collection actions for account linking flow

  def preload_accounts
    snaptrade_item = Current.family.snaptrade_items.first
    if snaptrade_item
      snaptrade_item.sync_later unless snaptrade_item.syncing?
      redirect_to setup_accounts_snaptrade_item_path(snaptrade_item)
    else
      redirect_to settings_providers_path, alert: t(".not_configured", default: "SnapTrade is not configured.")
    end
  end

  def select_accounts
    @accountable_type = params[:accountable_type]
    @return_to = params[:return_to]
    snaptrade_item = Current.family.snaptrade_items.first

    if snaptrade_item
      redirect_to setup_accounts_snaptrade_item_path(snaptrade_item, accountable_type: @accountable_type, return_to: @return_to)
    else
      redirect_to settings_providers_path, alert: t(".not_configured", default: "SnapTrade is not configured.")
    end
  end

  def link_accounts
    redirect_to settings_providers_path, alert: "Use the account setup flow instead"
  end

  def select_existing_account
    @account_id = params[:account_id]
    @account = Current.family.accounts.find_by(id: @account_id)
    snaptrade_item = Current.family.snaptrade_items.first

    if snaptrade_item && @account
      @snaptrade_accounts = snaptrade_item.snaptrade_accounts
        .left_joins(:account_provider)
        .where(account_providers: { id: nil })
      render :select_existing_account
    else
      redirect_to settings_providers_path, alert: t(".not_found", default: "Account or SnapTrade configuration not found.")
    end
  end

  def link_existing_account
    account_id = params[:account_id]
    snaptrade_account_id = params[:snaptrade_account_id]
    snaptrade_item_id = params[:snaptrade_item_id]

    account = Current.family.accounts.find_by(id: account_id)
    snaptrade_item = Current.family.snaptrade_items.find_by(id: snaptrade_item_id)
    snaptrade_account = snaptrade_item&.snaptrade_accounts&.find_by(id: snaptrade_account_id)

    if account && snaptrade_account
      begin
        # Create AccountProvider linking - pass the account directly
        provider = snaptrade_account.ensure_account_provider!(account)

        unless provider
          raise "Failed to create AccountProvider link"
        end

        # Trigger sync to process the linked account
        snaptrade_item.sync_later unless snaptrade_item.syncing?

        redirect_to account_path(account), notice: t(".success", default: "Successfully linked to SnapTrade account.")
      rescue => e
        Rails.logger.error "Failed to link existing account: #{e.message}"
        redirect_to settings_providers_path, alert: t(".failed", default: "Failed to link account: #{e.message}")
      end
    else
      redirect_to settings_providers_path, alert: t(".not_found", default: "Account not found.")
    end
  end

  private

    def set_snaptrade_item
      @snaptrade_item = Current.family.snaptrade_items.find(params[:id])
    end

    def snaptrade_item_params
      params.require(:snaptrade_item).permit(
        :name,
        :sync_start_date,
        :client_id,
        :consumer_key
      )
    end

    def build_connections_list
      # Fetch connections for current user from API
      api_connections = @snaptrade_item.fetch_connections

      # Get local accounts grouped by authorization_id
      local_accounts = @snaptrade_item.snaptrade_accounts
        .includes(:account_provider)
        .group_by(&:snaptrade_authorization_id)

      # Build unified list
      result = { connections: [], orphaned_users: [] }

      # Add connections from API for current user
      api_connections.each do |api_conn|
        auth_id = api_conn.id
        local_accts = local_accounts[auth_id] || []

        result[:connections] << {
          authorization_id: auth_id,
          brokerage_name: api_conn.brokerage&.name || I18n.t("snaptrade_items.connections.unknown_brokerage"),
          brokerage_slug: api_conn.brokerage&.slug,
          accounts: local_accts.map { |acct|
            { id: acct.id, name: acct.name, linked: acct.account_provider.present? }
          },
          orphaned_connection: local_accts.empty?
        }
      end

      # Add orphaned users (users registered but not current)
      orphaned = @snaptrade_item.orphaned_users
      orphaned.each do |user_id|
        result[:orphaned_users] << {
          user_id: user_id,
          display_name: user_id.truncate(30)
        }
      end

      result
    rescue Provider::Snaptrade::ApiError => e
      @error = e.message
      { connections: [], orphaned_users: [] }
    end

    def link_snaptrade_account(snaptrade_account)
      # Determine account type based on SnapTrade account type
      accountable_type = infer_accountable_type(snaptrade_account.account_type)

      # Create the Sure account
      account = Current.family.accounts.create!(
        name: snaptrade_account.name,
        balance: snaptrade_account.current_balance || 0,
        cash_balance: snaptrade_account.cash_balance || 0,
        currency: snaptrade_account.currency || Current.family.currency,
        accountable: accountable_type.constantize.new
      )

      # Link via AccountProvider - pass the account directly
      provider = snaptrade_account.ensure_account_provider!(account)

      unless provider
        Rails.logger.error "SnapTrade: Failed to create AccountProvider for snaptrade_account #{snaptrade_account.id}"
        raise "Failed to link account"
      end

      account
    end

    def infer_accountable_type(snaptrade_type)
      # SnapTrade account types: https://docs.snaptrade.com/reference/get_accounts
      case snaptrade_type&.downcase
      when "tfsa", "rrsp", "rrif", "resp", "rdsp", "lira", "lrsp", "lif", "rlsp", "prif",
           "401k", "403b", "457b", "ira", "roth_ira", "roth_401k", "sep_ira", "simple_ira",
           "pension", "retirement", "registered"
        "Investment" # Tax-advantaged accounts
      when "margin", "cash", "non-registered", "individual", "joint"
        "Investment" # Standard brokerage accounts
      when "crypto"
        "Crypto"
      else
        "Investment" # Default to Investment for brokerage accounts
      end
    end
end
