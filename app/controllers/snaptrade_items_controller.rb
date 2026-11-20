class SnaptradeItemsController < ApplicationController
  PERMITTED_OAUTH_SCOPES = %w[read].freeze
  # RFC 8628 §3.5: the authorization server is telling us to keep waiting, not
  # that anything went wrong.
  DEVICE_FLOW_PENDING_ERRORS = %w[authorization_pending slow_down].freeze
  # RFC 8628 §3.5: the two codes that mean this device code will never be
  # redeemable. Everything else -- a 5xx, a dropped connection -- leaves it
  # valid, so the user can just try again.
  DEVICE_FLOW_TERMINAL_ERRORS = %w[expired_token access_denied].freeze
  # What a pending device authorization needs to survive a retry render: the
  # code to redeem, plus what the page shows the user. expires_in and interval
  # are deliberately not kept -- nothing reads them, and the authorization
  # server is the one that decides when a code is spent.
  DEVICE_AUTHORIZATION_SESSION_FIELDS = %w[
    device_code user_code verification_uri verification_uri_complete
  ].freeze

  before_action :set_snaptrade_item, only: [ :show, :destroy, :sync, :connect, :setup_accounts, :complete_account_setup, :connections, :delete_connection, :complete_oauth_device_flow ]
  before_action :require_admin!, only: [ :destroy, :sync, :connect, :callback, :setup_accounts, :complete_account_setup, :connections, :delete_connection, :oauth_authorize, :oauth_callback, :oauth_device_authorize, :start_oauth_device_flow, :complete_oauth_device_flow, :preload_accounts, :select_accounts, :select_existing_account, :link_existing_account ]

  def index
    @snaptrade_items = Current.family.snaptrade_items.ordered
  end

  def show
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
      redirect_to settings_providers_path, alert: t(".no_item")
      return
    end

    snaptrade_item = Current.family.snaptrade_items.find_by(id: params[:item_id])

    if snaptrade_item
      snaptrade_item.sync_later_with_follow_up

      if params[:return_to].presence == "setup_accounts"
        redirect_to setup_accounts_snaptrade_item_path(snaptrade_item, accountable_type: params[:accountable_type].presence), notice: t(".success")
      else
        redirect_to accounts_path, notice: t(".success")
      end
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

    # We trigger an initial or recovery sync if there are no accounts, we aren't currently syncing,
    # and the last attempt didn't successfully complete. (If it completed and found 0 accounts, we stop here to avoid an infinite loop.)
    latest_sync = @snaptrade_item.syncs.ordered.first
    should_sync = latest_sync.nil? || !latest_sync.completed?

    if @snaptrade_item.oauth_configured? && no_accounts && !@snaptrade_item.syncing? && should_sync
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
      snaptrade_item: @snaptrade_item,
      error: @error
    }
  end

  # Start the SnapTrade OAuth authorization-code + PKCE flow
  def oauth_authorize
    unless Provider::Snaptrade.authorization_code_configured?
      redirect_to settings_providers_path, alert: t(".not_configured")
      return
    end

    snaptrade_item = if params[:item_id].present?
      Current.family.snaptrade_items.find(params[:item_id])
    else
      current_snaptrade_item || Current.family.snaptrade_items.create!(name: t("snaptrade_items.default_name"))
    end

    pkce = Provider::Snaptrade.generate_pkce
    state = SecureRandom.hex(32)

    session[:snaptrade_oauth] = {
      "state" => state,
      "code_verifier" => pkce[:verifier],
      "item_id" => snaptrade_item.id,
      "return_to" => params[:return_to].presence,
      "accountable_type" => params[:accountable_type].presence
    }

    redirect_to Provider::Snaptrade.authorize_url(
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

  # Device flow, step 0: the drawer, before any network call is made.
  def oauth_device_authorize
    assign_device_flow_context
    return render_device_flow_unconfigured unless Provider::Snaptrade.oauth_configured?

    @snaptrade_item = if params[:item_id].present?
      Current.family.snaptrade_items.find(params[:item_id])
    else
      current_snaptrade_item
    end

    render :oauth_device_flow
  end

  # Device flow, step 1: ask SnapTrade for the code the user confirms.
  def start_oauth_device_flow
    assign_device_flow_context
    return render_device_flow_unconfigured unless Provider::Snaptrade.oauth_configured?

    @snaptrade_item = if params[:item_id].present?
      Current.family.snaptrade_items.find(params[:item_id])
    else
      current_snaptrade_item || Current.family.snaptrade_items.create!(name: t("snaptrade_items.default_name"))
    end

    @device_authorization = @snaptrade_item.start_oauth_device_flow(scope: @oauth_scope)
    store_pending_device_flow(@device_authorization)

    render :oauth_device_flow
  rescue Provider::Snaptrade::Error => e
    Rails.logger.error "SnapTrade device authorization failed: #{e.class} - #{e.message}"
    @error_message = t(".failed")
    render :oauth_device_flow, status: :unprocessable_entity
  end

  # Device flow, step 2: redeem the confirmed code. From here the item is
  # indistinguishable from one authorized through the browser redirect.
  def complete_oauth_device_flow
    assign_device_flow_context

    device_flow = pending_device_flow
    if device_flow.blank?
      @error_message = t(".device_code_required")
      render :oauth_device_flow, status: :unprocessable_entity
      return
    end

    # The session is what says where this flow came from, so it decides where
    # it goes back to.
    @return_to = device_flow[:return_to]
    @accountable_type = device_flow[:accountable_type]

    @snaptrade_item.complete_oauth_device_flow!(device_code: device_flow[:device_code])
    session.delete(:snaptrade_device_flow)
    @snaptrade_item.sync_later_with_follow_up

    destination = if @return_to == "setup_accounts"
      setup_accounts_snaptrade_item_path(@snaptrade_item, accountable_type: @accountable_type.presence)
    else
      settings_providers_path
    end

    redirect_after_device_flow destination, notice: t(".success")
  rescue Provider::Snaptrade::Error => e
    Rails.logger.error "SnapTrade device token request failed: #{e.class} - #{e.message}"

    # Waiting on the user is the expected case, not a failure worth recording.
    unless device_flow_pending?(e)
      DebugLogEntry.capture(
        category: "provider_auth",
        level: :error,
        message: "SnapTrade device code exchange failed: #{e.message}",
        source: "SnaptradeItemsController#complete_oauth_device_flow",
        provider_key: "snaptrade",
        family: Current.family
      )
    end

    @error_message = device_flow_error_message(e)

    if DEVICE_FLOW_TERMINAL_ERRORS.include?(e.try(:oauth_error))
      # The code is spent. Drop it so the page offers a fresh start rather than
      # a button that can only fail.
      session.delete(:snaptrade_device_flow)
    else
      restore_device_authorization_from_session
    end

    render :oauth_device_flow, status: :unprocessable_entity
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
      if provider
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

  # Collection actions for account linking flow

  def preload_accounts
    snaptrade_item = current_snaptrade_item
    unless snaptrade_item
      redirect_to settings_providers_path, alert: t(".not_configured", default: "SnapTrade is not configured.")
      return
    end

    if snaptrade_item.oauth_configured?
      snaptrade_item.sync_later_with_follow_up
      redirect_to setup_accounts_snaptrade_item_path(snaptrade_item)
    else
      redirect_to helpers.snaptrade_authorize_path(item_id: snaptrade_item.id)
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

    if snaptrade_item.oauth_configured?
      redirect_to setup_accounts_snaptrade_item_path(snaptrade_item, accountable_type: @accountable_type, return_to: @return_to)
    else
      redirect_to helpers.snaptrade_authorize_path(item_id: snaptrade_item.id, accountable_type: @accountable_type, return_to: @return_to)
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
        active_items.ordered.first
    end

    def assign_device_flow_context
      @return_to = params[:return_to]
      @accountable_type = params[:accountable_type]
      @oauth_scope = permitted_oauth_scope
      @device_flow_available = Provider::Snaptrade.oauth_configured?
    end

    def permitted_oauth_scope
      requested_scope = params[:scope].to_s
      return requested_scope if PERMITTED_OAUTH_SCOPES.include?(requested_scope)

      "read"
    end

    # A device code redeems into tokens on its own and carries nothing that says
    # who asked for it, so the client is expected to keep it to itself. Holding
    # it in the session -- where the redirect flow already keeps its
    # code_verifier -- keeps it off the wire entirely and binds redemption to
    # the family and item that started the flow, which is the guarantee `state`
    # gives the redirect flow. Without that, a code recovered from anywhere
    # could be redeemed into someone else's item.
    def store_pending_device_flow(payload)
      pending = DEVICE_AUTHORIZATION_SESSION_FIELDS.index_with { |field| payload[field] }

      session[:snaptrade_device_flow] = pending.merge(
        "family_id" => Current.family.id,
        "item_id" => @snaptrade_item.id,
        "return_to" => @return_to,
        "accountable_type" => @accountable_type
      )
    end

    def pending_device_flow
      device_flow = (session[:snaptrade_device_flow] || {}).with_indifferent_access

      return nil if device_flow[:device_code].blank?
      return nil unless device_flow[:family_id].to_s == Current.family.id.to_s
      return nil unless device_flow[:item_id].to_s == @snaptrade_item.id.to_s

      device_flow
    end

    # The device code survives a failed attempt: the user code is still valid,
    # so re-rendering the same page lets them finish in SnapTrade and retry
    # without starting over.
    def restore_device_authorization_from_session
      device_flow = (session[:snaptrade_device_flow] || {}).with_indifferent_access

      @device_authorization = device_flow.slice(*DEVICE_AUTHORIZATION_SESSION_FIELDS).to_h
    end

    def render_device_flow_unconfigured
      @device_flow_available = false
      @error_message = t("snaptrade_items.oauth_device_flow.missing_client_id")
      render :oauth_device_flow, status: :unprocessable_entity
    end

    # The drawer form posts into the `drawer` frame so errors re-render in
    # place. A plain redirect would be followed as a frame navigation, and both
    # destinations carry the layout's empty `drawer` frame -- Turbo would swap
    # that in and just close the dialog, losing the notice and never advancing
    # to account setup. A redirect stream action breaks out to the top level.
    def redirect_after_device_flow(path, notice:)
      if turbo_frame_request?
        flash[:notice] = notice
        render turbo_stream: turbo_stream.action(:redirect, path)
      else
        redirect_to path, notice: notice
      end
    end

    def device_flow_pending?(error)
      DEVICE_FLOW_PENDING_ERRORS.include?(error.try(:oauth_error))
    end

    # Chosen from the machine-readable OAuth code only. error.message can carry
    # upstream detail, so it never reaches the page.
    def device_flow_error_message(error)
      return t("snaptrade_items.complete_oauth_device_flow.authorization_pending") if device_flow_pending?(error)

      case error.try(:oauth_error)
      when "expired_token"
        t("snaptrade_items.complete_oauth_device_flow.expired")
      when "access_denied"
        t("snaptrade_items.complete_oauth_device_flow.access_denied")
      else
        t("snaptrade_items.complete_oauth_device_flow.failed")
      end
    end

    def build_connections_list
      api_connections = @snaptrade_item.fetch_connections

      local_accounts = @snaptrade_item.snaptrade_accounts
        .includes(:account_provider)
        .group_by(&:snaptrade_authorization_id)

      result = { connections: [] }

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

      result
    rescue Provider::Snaptrade::ApiError => e
      @error = e.message
      { connections: [] }
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
