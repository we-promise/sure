class SnaptradeItemsController < ApplicationController
  PERMITTED_OAUTH_SCOPES = %w[read].freeze

  before_action :set_snaptrade_item, only: [ :show, :edit, :update, :destroy, :sync, :connect, :setup_accounts, :complete_account_setup, :connections, :start_oauth_device_flow, :complete_oauth_device_flow, :delete_connection, :delete_orphaned_user ]
  before_action :require_admin!, only: [ :new, :create, :edit, :update, :destroy, :sync, :connect, :callback, :setup_accounts, :complete_account_setup, :connections, :delete_connection, :delete_orphaned_user, :oauth_connect, :start_oauth_connect, :start_oauth_device_flow, :complete_oauth_device_flow, :oauth_authorize, :oauth_callback, :preload_accounts, :select_accounts, :select_existing_account, :link_existing_account ]

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
      register_snaptrade_user(@snaptrade_item)
      render_panel_success(t(".success", default: "Successfully configured SnapTrade."))
    else
      render_panel_error(@snaptrade_item.errors.full_messages.join(", "))
    end
  end

  def update
    if @snaptrade_item.update(snaptrade_item_params)
      register_snaptrade_user(@snaptrade_item)
      render_panel_success(t(".success", default: "Successfully updated SnapTrade configuration."))
    else
      render_panel_error(@snaptrade_item.errors.full_messages.join(", "))
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
    @snaptrade_item.ensure_user_registered! if @snaptrade_item.device_flow? && !@snaptrade_item.user_registered?

    redirect_url = callback_snaptrade_items_url(
      item_id: @snaptrade_item.id,
      return_to: params[:return_to].presence,
      accountable_type: params[:accountable_type].presence
    )
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
      clear_snaptrade_resume_context
      redirect_to settings_providers_path, alert: t(".no_item")
      return
    end

    snaptrade_item = Current.family.snaptrade_items.find_by(id: params[:item_id])

    if snaptrade_item
      snaptrade_item.sync_later_with_follow_up

      stored_return_to, stored_accountable_type = clear_snaptrade_resume_context
      return_to = params[:return_to].presence || stored_return_to
      accountable_type = params[:accountable_type].presence || stored_accountable_type

      if return_to == "setup_accounts"
        redirect_to setup_accounts_snaptrade_item_path(snaptrade_item, accountable_type: accountable_type.presence), notice: t(".success")
      else
        redirect_to accounts_path, notice: t(".success")
      end
    else
      clear_snaptrade_resume_context
      redirect_to settings_providers_path, alert: t(".no_item")
    end
  end

  # Show available accounts for linking
  def setup_accounts
    @snaptrade_accounts = @snaptrade_item.snaptrade_accounts.includes(account_provider: :account)
    @linked_accounts = @snaptrade_accounts.select { |sa| sa.current_account.present? }
    @unlinked_accounts = @snaptrade_accounts.reject { |sa| sa.current_account.present? }

    no_accounts = @unlinked_accounts.blank? && @linked_accounts.blank?

    # We trigger an initial or recovery sync if there are no accounts, we aren't currently syncing,
    # and the last attempt didn't successfully complete. (If it completed and found 0 accounts, we stop here to avoid an infinite loop.)
    latest_sync = @snaptrade_item.syncs.ordered.first
    should_sync = latest_sync.nil? || !latest_sync.completed?

    if @snaptrade_item.fully_configured? && no_accounts && !@snaptrade_item.syncing? && should_sync
      @snaptrade_item.sync_later
    end

    # Existing unlinked, visible investment/crypto accounts that could be linked instead of creating duplicates
    @linkable_accounts = Current.family.accounts
      .visible
      .where(accountable_type: %w[Investment Crypto])
      .left_joins(:account_providers)
      .where(account_providers: { id: nil })
      .order(:name)

    @account_type_options = [
      [ t(".account_types.depository"), "Depository" ],
      [ t(".account_types.credit_card"), "CreditCard" ],
      [ t(".account_types.investment"), "Investment" ],
      [ t(".account_types.crypto"), "Crypto" ],
      [ t(".account_types.loan"), "Loan" ],
      [ t(".account_types.other_asset"), "OtherAsset" ]
    ]

    # Determine view state
    @syncing = @snaptrade_item.syncing?
    @waiting_for_sync = no_accounts && @syncing
    @no_accounts_found = no_accounts && !@syncing && @snaptrade_item.last_synced_at.present?
  end

  # Link selected accounts to Sure
  def complete_account_setup
    Rails.logger.info "SnapTrade complete_account_setup - params: #{params.to_unsafe_h.inspect}"
    account_ids = params[:account_ids] || []
    account_types = params[:account_types] || {}
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
        link_snaptrade_account(snaptrade_account, account_types[snaptrade_account_id])
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
        redirect_to accounts_path,
                    notice: t(".partial_success", count: linked_count, failed_count: errors.size,
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

  # --- OAuth device flow (the supported way to connect) ---

  def oauth_connect
    assign_oauth_connect_context

    unless Provider::Snaptrade.oauth_client_id_configured?
      @error_message = snaptrade_oauth_client_id_missing_message
      render :oauth_device_flow, status: :unprocessable_entity, formats: :html
      return
    end

    @snaptrade_item = if params[:item_id].present?
      Current.family.snaptrade_items.find(params[:item_id])
    else
      current_snaptrade_item
    end

    return unless require_api_credentials_for_device_flow!

    render :oauth_device_flow
  rescue ActiveRecord::Encryption::Errors::Decryption => e
    Rails.logger.error "SnapTrade decryption error for item #{@snaptrade_item&.id}: #{e.class} - #{e.message}"
    @error_message = t("snaptrade_items.connect.decryption_failed")
    render :oauth_device_flow, status: :unprocessable_entity, formats: :html
  rescue ActiveRecord::ActiveRecordError, ActiveRecord::Encryption::Errors::Base => e
    Rails.logger.error "SnapTrade OAuth connect error: #{e.class} - #{e.message}"
    @error_message = start_oauth_device_flow_error_message
    render :oauth_device_flow, status: :unprocessable_entity, formats: :html
  end

  def start_oauth_connect
    assign_oauth_connect_context

    unless Provider::Snaptrade.oauth_client_id_configured?
      @error_message = snaptrade_oauth_client_id_missing_message
      render :oauth_device_flow, status: :unprocessable_entity, formats: :html
      return
    end

    @snaptrade_item = if params[:item_id].present?
      Current.family.snaptrade_items.find(params[:item_id])
    else
      current_snaptrade_item
    end

    return unless require_api_credentials_for_device_flow!

    @device_authorization = @snaptrade_item.start_oauth_device_flow(scope: @oauth_scope)

    render :oauth_device_flow
  rescue ActiveRecord::Encryption::Errors::Decryption => e
    Rails.logger.error "SnapTrade decryption error for item #{@snaptrade_item&.id}: #{e.class} - #{e.message}"
    @error_message = t("snaptrade_items.connect.decryption_failed")
    render :oauth_device_flow, status: :unprocessable_entity, formats: :html
  rescue Provider::Snaptrade::Error, ActiveRecord::ActiveRecordError, ActiveRecord::Encryption::Errors::Base => e
    Rails.logger.error "SnapTrade OAuth connect error: #{e.class} - #{e.message}"
    @error_message = oauth_connect_error_message(e)
    render :oauth_device_flow, status: :unprocessable_entity, formats: :html
  end

  def start_oauth_device_flow
    unless @snaptrade_item.api_credentials_configured?
      render json: { error: snaptrade_api_credentials_required_message }, status: :unprocessable_entity
      return
    end

    render json: @snaptrade_item.start_oauth_device_flow(scope: permitted_oauth_scope)
  rescue ActiveRecord::Encryption::Errors::Decryption => e
    Rails.logger.error "SnapTrade decryption error for item #{@snaptrade_item.id}: #{e.class} - #{e.message}"
    render json: { error: t("snaptrade_items.connect.decryption_failed") }, status: :unprocessable_entity
  rescue Provider::Snaptrade::Error => e
    Rails.logger.error "SnapTrade OAuth device authorization error: #{e.class} - #{e.message}"
    render json: { error: start_oauth_device_flow_error_message }, status: :unprocessable_entity
  end

  def complete_oauth_device_flow
    # Applying device-flow tokens overwrites whatever is in the oauth_* columns.
    # On a connection still running on #2747's PKCE tokens that would destroy a
    # working connection, so the device flow only runs once the item has the
    # API credentials that make it a device-flow connection in the first place.
    unless @snaptrade_item.api_credentials_configured?
      if request.format.json?
        render json: { error: snaptrade_api_credentials_required_message }, status: :unprocessable_entity
      else
        @error_message = snaptrade_api_credentials_required_message
        restore_device_authorization_from_params
        render :oauth_device_flow, status: :unprocessable_entity, formats: :html
      end
      return
    end

    if params[:device_code].blank?
      render json: { error: t("snaptrade_items.complete_oauth_device_flow.device_code_required") }, status: :unprocessable_entity
      return
    end

    token_response = @snaptrade_item.complete_oauth_device_flow!(device_code: params[:device_code])
    if request.format.json?
      render json: {
        token_type: token_response["token_type"],
        scope: token_response["scope"],
        expires_in: token_response["expires_in"],
        expires_at: @snaptrade_item.oauth_token_expires_at&.iso8601
      }
    else
      if prepare_snaptrade_item_for_setup_after_oauth
        redirect_after_oauth_completion setup_accounts_snaptrade_item_path(
          @snaptrade_item,
          accountable_type: params[:accountable_type].presence,
          return_to: params[:return_to].presence
        ), notice: t(".success", default: "SnapTrade authorization complete.")
      else
        redirect_after_oauth_completion settings_providers_path, alert: snaptrade_oauth_setup_incomplete_message
      end
    end
  rescue Provider::Snaptrade::ApiError => e
    if request.format.json?
      render json: oauth_error_payload(e), status: e.status_code || :unprocessable_entity
    else
      payload = oauth_error_payload(e)
      @error_message = payload["error_description"].presence || payload["error"]
      restore_device_authorization_from_params
      render :oauth_device_flow, status: e.status_code || :unprocessable_entity, formats: :html
    end
  rescue Provider::Snaptrade::Error, ActiveRecord::ActiveRecordError, ActiveRecord::Encryption::Errors::Base => e
    Rails.logger.error "SnapTrade OAuth device token error: #{e.class} - #{e.message}"
    if request.format.json?
      render json: { error: complete_oauth_device_flow_error_message }, status: :unprocessable_entity
    else
      @error_message = complete_oauth_device_flow_error_message
      restore_device_authorization_from_params
      render :oauth_device_flow, status: :unprocessable_entity, formats: :html
    end
  end

  # --- DEPRECATED authorization-code + PKCE flow (#2747) ---
  #
  # Closed to new connections. It stays reachable only so a connection already
  # authorized under PKCE can re-consent when its refresh token dies, rather
  # than being stranded before its owner has migrated to the device flow.

  def oauth_authorize
    snaptrade_item = params[:item_id].present? ? Current.family.snaptrade_items.find_by(id: params[:item_id]) : nil

    unless snaptrade_item&.legacy_oauth?
      redirect_to oauth_connect_snaptrade_items_path(
        return_to: params[:return_to].presence,
        accountable_type: params[:accountable_type].presence
      ), notice: t(".deprecated")
      return
    end

    unless Provider::SnaptradeOauth.oauth_configured?
      redirect_to settings_providers_path, alert: t(".not_configured")
      return
    end

    pkce = Provider::SnaptradeOauth.generate_pkce
    state = SecureRandom.hex(32)

    session[:snaptrade_oauth] = {
      "state" => state,
      "code_verifier" => pkce[:verifier],
      "item_id" => snaptrade_item.id,
      "return_to" => params[:return_to].presence,
      "accountable_type" => params[:accountable_type].presence
    }

    redirect_to Provider::SnaptradeOauth.authorize_url(
      redirect_uri: oauth_callback_snaptrade_items_url,
      state: state,
      code_challenge: pkce[:challenge]
    ), allow_other_host: true
  end

  # Registered OAuth redirect URI: verify state, exchange code, store tokens
  def oauth_callback
    oauth_session = (session.delete(:snaptrade_oauth) || {}).with_indifferent_access

    if params[:error].present?
      Rails.logger.warn "SnapTrade OAuth callback error: #{params[:error]}"
      alert = params[:error] == "access_denied" ? t(".access_denied") : t(".failed")
      redirect_to settings_providers_path, alert: alert
      return
    end

    unless params[:state].present? && oauth_session[:state].present? &&
           ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, oauth_session[:state].to_s)
      redirect_to settings_providers_path, alert: t(".state_mismatch")
      return
    end

    snaptrade_item = Current.family.snaptrade_items.find_by(id: oauth_session[:item_id])
    unless snaptrade_item && params[:code].present?
      redirect_to settings_providers_path, alert: t(".failed")
      return
    end

    snaptrade_item.complete_oauth_exchange!(
      code: params[:code],
      redirect_uri: oauth_callback_snaptrade_items_url,
      code_verifier: oauth_session[:code_verifier]
    )

    snaptrade_item.sync_later_with_follow_up

    if oauth_session[:return_to] == "setup_accounts"
      redirect_to setup_accounts_snaptrade_item_path(snaptrade_item, accountable_type: oauth_session[:accountable_type].presence), notice: t(".success")
    else
      redirect_to settings_providers_path, notice: t(".success")
    end
  rescue Provider::Snaptrade::Error => e
    Rails.logger.error "SnapTrade OAuth exchange failed: #{e.class} - #{e.message}"
    DebugLogEntry.capture(
      category: "provider_auth",
      level: :error,
      message: "SnapTrade OAuth code exchange failed: #{e.message}",
      source: "SnaptradeItemsController#oauth_callback",
      provider_key: "snaptrade",
      family: Current.family
    )
    redirect_to settings_providers_path, alert: t(".failed")
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
      if provider && @snaptrade_item.fully_configured?
        provider.delete_connection(authorization_id: authorization_id)
      else
        Rails.logger.warn "SnapTrade: Cannot delete orphaned connection #{authorization_id} - item not authorized"
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
    snaptrade_item = current_snaptrade_item
    unless snaptrade_item
      redirect_to settings_providers_path, alert: t(".not_configured", default: "SnapTrade is not configured.")
      return
    end

    if snaptrade_item.fully_configured?
      snaptrade_item.sync_later_with_follow_up
      redirect_to setup_accounts_snaptrade_item_path(snaptrade_item)
    else
      redirect_to oauth_connect_snaptrade_items_path(item_id: snaptrade_item.id)
    end
  end

  def select_accounts
    @accountable_type = params[:accountable_type]
    @return_to = params[:return_to]
    snaptrade_item = current_snaptrade_item

    unless snaptrade_item
      redirect_to settings_providers_path, alert: t(".not_configured", default: "SnapTrade is not configured.")
      return
    end

    if snaptrade_item.fully_configured?
      redirect_to setup_accounts_snaptrade_item_path(snaptrade_item, accountable_type: @accountable_type, return_to: @return_to)
    else
      store_snaptrade_resume_context(return_to: @return_to, accountable_type: @accountable_type)
      redirect_to oauth_connect_snaptrade_items_path(item_id: snaptrade_item.id, accountable_type: @accountable_type, return_to: @return_to)
    end
  end

  def select_existing_account
    @account_id = params[:account_id]
    @account = Current.family.accounts.find_by(id: @account_id)
    snaptrade_item = current_snaptrade_item

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
        snaptrade_item.sync_later_with_follow_up

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

    def current_snaptrade_item
      active_items = Current.family.snaptrade_items.active

      active_items.syncable.ordered.first ||
        active_items.api_credentials_configured.ordered.first ||
        active_items.ordered.first
    end

    # Registration failures shouldn't fail the credential save - the panel
    # surfaces the "registration needed" state and the user can retry.
    def register_snaptrade_user(snaptrade_item)
      return unless snaptrade_item.api_credentials_configured?

      snaptrade_item.ensure_user_registered!
    rescue => e
      Rails.logger.error "SnapTrade user registration failed: #{e.message}"
    end

    def render_panel_success(message)
      if turbo_frame_request?
        flash.now[:notice] = message
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
        redirect_to settings_providers_path, notice: message, status: :see_other
      end
    end

    def render_panel_error(message)
      @error_message = message

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "snaptrade-providers-panel",
          partial: "settings/providers/snaptrade_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end

    def store_snaptrade_resume_context(return_to:, accountable_type:)
      session[:snaptrade_resume] = {
        return_to: return_to,
        accountable_type: accountable_type
      }
    end

    def clear_snaptrade_resume_context
      resume = (session.delete(:snaptrade_resume) || {}).with_indifferent_access
      [ resume[:return_to], resume[:accountable_type] ]
    end

    def restore_device_authorization_from_params
      @device_authorization = params.permit(
        :device_code,
        :user_code,
        :verification_uri,
        :verification_uri_complete,
        :expires_in,
        :interval
      ).to_h
      @return_to = params[:return_to]
      @accountable_type = params[:accountable_type]
    end

    def assign_oauth_connect_context
      @return_to = params[:return_to]
      @accountable_type = params[:accountable_type]
      @oauth_scope = permitted_oauth_scope
    end

    def permitted_oauth_scope
      requested_scope = params[:scope].to_s
      return requested_scope if PERMITTED_OAUTH_SCOPES.include?(requested_scope)

      "read"
    end

    def prepare_snaptrade_item_for_setup_after_oauth
      if !@snaptrade_item.user_registered? && @snaptrade_item.api_credentials_configured?
        @snaptrade_item.ensure_user_registered!
      end

      return false unless @snaptrade_item.fully_configured?

      @snaptrade_item.sync_later_with_follow_up
      true
    rescue Provider::Snaptrade::Error => e
      Rails.logger.error "SnapTrade user registration after authorization failed: #{e.class} - #{e.message}"
      false
    end

    def redirect_after_oauth_completion(path, notice: nil, alert: nil)
      if turbo_frame_request?
        flash[:notice] = notice if notice.present?
        flash[:alert] = alert if alert.present?
        render turbo_stream: turbo_stream.action(:redirect, path)
      else
        redirect_to path, notice: notice, alert: alert
      end
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
      api_connections = @snaptrade_item.fetch_connections

      local_accounts = @snaptrade_item.snaptrade_accounts
        .includes(:account_provider)
        .group_by(&:snaptrade_authorization_id)

      result = { connections: [], orphaned_users: [] }

      api_connections.each do |api_conn|
        auth_id = api_conn["id"]
        local_accts = local_accounts[auth_id] || []

        result[:connections] << {
          authorization_id: auth_id,
          brokerage_name: api_conn.dig("brokerage", "name") || I18n.t("snaptrade_items.connections.unknown_brokerage"),
          brokerage_slug: api_conn.dig("brokerage", "slug"),
          accounts: local_accts.map { |acct|
            { id: acct.id, name: acct.name, linked: acct.account_provider.present? }
          },
          orphaned_connection: local_accts.empty?
        }
      end

      # Users left over from earlier registrations still hold connection slots.
      # Only the device flow registers SnapTrade users, so legacy items have none.
      @snaptrade_item.orphaned_users.each do |user_id|
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

    def oauth_error_payload(error)
      parsed_body = parse_oauth_error_body(error.response_body)
      payload = parsed_body.slice("error", "error_description", "error_uri", "interval")
      payload["error"] ||= error.message
      payload
    end

    def start_oauth_device_flow_error_message
      t(
        "snaptrade_items.start_oauth_device_flow.failed",
        default: "Unable to start SnapTrade OAuth device authorization. Please try again."
      )
    end

    def oauth_connect_error_message(error)
      if error.is_a?(Provider::Snaptrade::ConfigurationError) && error.message.include?("OAuth client ID")
        snaptrade_oauth_client_id_missing_message
      else
        start_oauth_device_flow_error_message
      end
    end

    # The device flow needs the family's API credentials before it runs: they
    # are what makes the resulting connection a device-flow one, and what its
    # data calls are scoped by. Renders the drawer explaining that rather than
    # starting a ceremony whose tokens we could not use.
    def require_api_credentials_for_device_flow!
      return true if @snaptrade_item&.api_credentials_configured?

      @error_message = snaptrade_api_credentials_required_message
      render :oauth_device_flow, status: :unprocessable_entity, formats: :html
      false
    end

    def snaptrade_api_credentials_required_message
      t(
        "snaptrade_items.oauth_device_flow.credentials_required",
        default: "Add your SnapTrade Client ID and Consumer Key first, then authorize with a device code."
      )
    end

    def snaptrade_oauth_client_id_missing_message
      t(
        "snaptrade_items.oauth_device_flow.missing_client_id",
        default: "SnapTrade OAuth client ID is not configured. Add SNAPTRADE_OAUTH_CLIENT_ID to .env.local, restart the app, then try again."
      )
    end

    def snaptrade_oauth_setup_incomplete_message
      t(
        "snaptrade_items.complete_oauth_device_flow.setup_incomplete",
        default: "SnapTrade authorization is complete, but API credentials are required before accounts can sync."
      )
    end

    def complete_oauth_device_flow_error_message
      t(
        "snaptrade_items.complete_oauth_device_flow.failed",
        default: "Unable to complete SnapTrade OAuth device authorization. Please try again."
      )
    end

    def parse_oauth_error_body(response_body)
      return {} if response_body.blank?

      parsed_body = JSON.parse(response_body)
      parsed_body.is_a?(Hash) ? parsed_body : {}
    rescue JSON::ParserError
      {}
    end

    def link_snaptrade_account(snaptrade_account, selected_type)
      accountable_type = selected_type.presence || snaptrade_account.suggested_account_type
      unless Accountable::TYPES.include?(accountable_type)
        raise ArgumentError, "Invalid SnapTrade account type: #{accountable_type}"
      end

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
end
