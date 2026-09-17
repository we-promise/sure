class TradeRepublicItemsController < ApplicationController
  before_action :set_trade_republic_item, only: [ :show, :update, :destroy, :sync, :repair, :setup_accounts, :complete_account_setup, :initiate_login, :complete_login, :poll_login, :initiate_qr_login, :poll_qr_login, :cancel_qr_login ]
  before_action :require_admin!, only: [ :show, :create, :select_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :repair, :setup_accounts, :complete_account_setup, :initiate_login, :complete_login, :poll_login, :initiate_qr_login, :poll_qr_login, :cancel_qr_login ]

  def show
    redirect_to settings_providers_path(anchor: "trade-republic")
  end

  def create
    qr_login_requested = params[:login_method] == "qr" || params.dig(:trade_republic_item, :login_method) == "qr"
    @trade_republic_item = Current.family.trade_republic_items.build(trade_republic_item_params)
    login_pin = @trade_republic_item.pin
    @trade_republic_item.name ||= t("trade_republic_items.defaults.name")
    @trade_republic_item.currency ||= Current.family.currency
    @trade_republic_item.status = :requires_update if qr_login_requested

    if !qr_login_requested && login_pin.blank?
      render_panel_error(t("trade_republic_items.initiate_login.pin_required"))
      return
    end

    if @trade_republic_item.save
      if qr_login_requested
        initiate_qr_login_for(@trade_republic_item)
      else
        initiate_login_for(@trade_republic_item, pin: login_pin)
      end

      if turbo_panel_request?
        if @error_message.present?
          flash.now[:alert] = @error_message
        else
          flash.now[:notice] = t(".success")
        end
        render turbo_stream: [
          turbo_stream.replace(
            "trade-republic-providers-panel",
            partial: "settings/providers/trade_republic_panel",
            locals: {
              trade_republic_item: @trade_republic_item,
              qr_code_svg: @qr_code_svg,
              qr_login_auto_poll: qr_login_requested && @error_message.blank?
            }
          ),
          *flash_notification_stream_items
        ]
      elsif @error_message.present?
        redirect_to settings_providers_path(anchor: "trade-republic"), alert: @error_message, status: :see_other
      else
        redirect_to accounts_path, **redirect_flash_options(t(".success")), status: :see_other
      end
    else
      render_panel_error(@trade_republic_item.errors.full_messages.join(", "))
    end
  end

  # Step 1 of authentication: starts a Trade Republic web login and stores the
  # in-flight login state (encrypted) on the item. The user then confirms via
  # push notification or authenticator code; no web request blocks on that.
  def initiate_login
    provider = @trade_republic_item.trade_republic_provider
    unless provider
      redirect_to settings_providers_path, alert: t(".not_configured"), status: :see_other
      return
    end

    if @trade_republic_item.pin.blank?
      @trade_republic_item.update!(pending_login_state: nil, status: :requires_update) if @trade_republic_item.pending_login_state.present?
      return render_login_panel(alert: t(".pin_required")) if turbo_panel_request?

      respond_to do |format|
        format.html { redirect_to settings_providers_path(anchor: "trade-republic"), alert: t(".pin_required"), status: :see_other }
        format.json { render json: { error: t(".pin_required") }, status: :unprocessable_entity }
      end
      return
    end

    invalidate_authentication!
    result = @trade_republic_item.trade_republic_provider.initiate_login
    @trade_republic_item.update!(
      pending_login_state: result["pending_login_b64"],
      status: :requires_update
    )

    respond_to do |format|
      format.html { redirect_to settings_providers_path(anchor: "trade-republic"), notice: t(".verification_required", method: result["method"]) }
      format.json { head :ok }
    end
  rescue Provider::TradeRepublicClient::Error => e
    redirect_to settings_providers_path(anchor: "trade-republic"), alert: e.message, status: :see_other
  end

  # Step 2 of authentication: completes the started login. For push accounts
  # this is retried until Trade Republic reports CONFIRMED (status "pending");
  # authenticator accounts submit their code here. Success replaces the stored
  # session blob and clears the pending login state.
  def complete_login
    provider = @trade_republic_item.trade_republic_provider
    unless provider && @trade_republic_item.pending_login_state.present?
      redirect_to settings_providers_path(anchor: "trade-republic"), alert: t(".no_pending_login"), status: :see_other
      return
    end

    result = provider.complete_login(
      pending_login_b64: @trade_republic_item.pending_login_state,
      code: trade_republic_login_params[:code]
    )

    if result.data["status"] == "pending"
      @trade_republic_item.update!(pending_login_state: result.data.fetch("pending_login_b64")) if result.data["pending_login_b64"].present?
      if turbo_panel_request?
        render_login_panel(notice: t(".approval_pending"))
      else
        redirect_to settings_providers_path(anchor: "trade-republic"), notice: t(".approval_pending")
      end
    else
      ActiveRecord::Base.transaction do
        @trade_republic_item.update!(
          session_blob: result.data.fetch("session_txt"),
          pending_login_state: nil,
          status: :good
        )
      end
      @trade_republic_item.sync_later unless @trade_republic_item.syncing?
      if turbo_panel_request?
        render_login_panel(success: true)
      else
        redirect_to settings_providers_path(anchor: "trade-republic"), notice: t(".success")
      end
    end
  rescue Provider::TradeRepublicClient::InvalidChallenge => e
    redirect_to settings_providers_path(anchor: "trade-republic"), alert: e.message, status: :see_other
  rescue Provider::TradeRepublicClient::LoginExpired, Provider::TradeRepublicClient::AuthenticationRequired
    @trade_republic_item.update!(pending_login_state: nil)
    redirect_to settings_providers_path(anchor: "trade-republic"), alert: t(".login_expired"), status: :see_other
  rescue Provider::TradeRepublicClient::Error => e
    redirect_to settings_providers_path(anchor: "trade-republic"), alert: e.message, status: :see_other
  end

  # Push approvals are asynchronous. The browser polls this endpoint while
  # the user approves the login in the Trade Republic app (maximum two minutes).
  def poll_login
    provider = @trade_republic_item.trade_republic_provider
    unless provider && @trade_republic_item.pending_login_state.present?
      return render_login_panel(alert: t(".no_pending_login"))
    end

    result = provider.complete_login(pending_login_b64: @trade_republic_item.pending_login_state)
    if result.data["status"] == "pending"
      @trade_republic_item.update!(pending_login_state: result.data.fetch("pending_login_b64")) if result.data["pending_login_b64"].present?
      render_login_panel
    else
      @trade_republic_item.update!(session_blob: result.data.fetch("session_txt"), pending_login_state: nil, status: :good)
      @trade_republic_item.sync_later unless @trade_republic_item.syncing?
      render_login_panel(success: true)
    end
  rescue Provider::TradeRepublicClient::LoginExpired, Provider::TradeRepublicClient::AuthenticationRequired
    @trade_republic_item.update!(pending_login_state: nil)
    render_login_panel(alert: t(".login_expired"))
  rescue Provider::TradeRepublicClient::Error => e
    render_login_panel(alert: e.message)
  end

  def initiate_qr_login
    provider = @trade_republic_item.trade_republic_provider
    raise Provider::TradeRepublicClient::ConfigurationError, t(".not_configured") unless provider

    invalidate_authentication!
    result = provider.initiate_qr_login
    @trade_republic_item.update!(pending_login_state: result.data.fetch("pending_login_b64"), status: :requires_update)
    response_data = result.data.except("pending_login_b64")
    response_data["qr_code_svg"] = view_context.generate_mfa_qr_code(result.data["qr_code_payload"]) if result.data["qr_code_payload"].present?
    render json: response_data, status: :accepted
  rescue Provider::TradeRepublicClient::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def poll_qr_login
    provider = @trade_republic_item.trade_republic_provider
    pending = @trade_republic_item.pending_login_state
    raise Provider::TradeRepublicClient::InvalidChallenge, t(".no_pending_login") if provider.blank? || pending.blank?

    result = provider.poll_qr_login(pending_login_b64: pending)
    if result.data["status"] == "pending"
      @trade_republic_item.update!(pending_login_state: result.data.fetch("pending_login_b64"))
      response_data = result.data.except("pending_login_b64")
      response_data["qr_code_svg"] = view_context.generate_mfa_qr_code(result.data["qr_code_payload"]) if result.data["qr_code_payload"].present?
      render json: response_data
    else
      @trade_republic_item.update!(session_blob: result.data.fetch("session_txt"), pending_login_state: nil, status: :good)
      @trade_republic_item.sync_later unless @trade_republic_item.syncing?
      flash[:notice] = t(".success")
      render json: result.data.except("session_txt")
    end
  rescue Provider::TradeRepublicClient::LoginExpired, Provider::TradeRepublicClient::AuthenticationRequired => e
    @trade_republic_item.update!(pending_login_state: nil)
    render json: { error: e.message }, status: :unprocessable_entity
  rescue Provider::TradeRepublicClient::RateLimited => e
    render_qr_login_error(e, status: :too_many_requests, retryable: true)
  rescue Provider::TradeRepublicClient::Timeout,
         Provider::TradeRepublicClient::TransientProviderError => e
    render_qr_login_error(e, status: :service_unavailable, retryable: true)
  rescue Provider::TradeRepublicClient::Error => e
    render_qr_login_error(e)
  end

  def cancel_qr_login
    @trade_republic_item.update!(pending_login_state: nil, status: :requires_update)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "trade-republic-providers-panel",
          partial: "settings/providers/trade_republic_panel",
          locals: { trade_republic_item: @trade_republic_item }
        )
      end
      format.json { render json: { status: "cancelled" } }
    end
  end

  def update
    attrs = trade_republic_item_params.to_h
    login_pin = attrs["pin"]
    reauthentication_required = reauthentication_needed?(attrs)

    if reauthentication_required && login_pin.blank?
      render_panel_error(t(".pin_required"))
      return
    end

    if @trade_republic_item.update(attrs)
      initiate_login_for(@trade_republic_item, pin: login_pin) if reauthentication_required

      if turbo_panel_request?
        if @error_message.present?
          flash.now[:alert] = @error_message
        else
          flash.now[:notice] = t(".success")
        end
        render turbo_stream: [
          turbo_stream.replace(
            "trade-republic-providers-panel",
            partial: "settings/providers/trade_republic_panel",
            locals: { trade_republic_item: @trade_republic_item }
          ),
          *flash_notification_stream_items
        ]
      elsif @error_message.present?
        redirect_to settings_providers_path(anchor: "trade-republic"), alert: @error_message, status: :see_other
      else
        redirect_to accounts_path, **redirect_flash_options(t(".success")), status: :see_other
      end
    else
      render_panel_error(@trade_republic_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    unlink_results = @trade_republic_item.unlink_all!(dry_run: false)
    if unlink_results.any? { |result| result[:error].present? }
      redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
      return
    end

    @trade_republic_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @trade_republic_item.sync_later unless @trade_republic_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def repair
    TradeRepublicRepairJob.perform_later(@trade_republic_item)
    redirect_back_or_to accounts_path, notice: t("trade_republic_items.repair.scheduled"), status: :see_other
  end

  def select_accounts
    item = current_trade_republic_item
    unless item
      redirect_to settings_providers_path, alert: t(".not_configured")
      return
    end

    redirect_to setup_accounts_trade_republic_item_path(item)
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @available_trade_republic_accounts = Current.family.trade_republic_items
      .active
      .includes(trade_republic_accounts: { account_provider: :account })
      .flat_map(&:trade_republic_accounts)
      .select { |tr_account| tr_account.account_provider.nil? }
      .sort_by { |tr_account| tr_account.updated_at || tr_account.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find_by(id: params[:account_id])
    item = Current.family.trade_republic_items.active.joins(:trade_republic_accounts)
                  .where(trade_republic_accounts: { id: params[:trade_republic_account_id] })
                  .first
    tr_account = item&.trade_republic_accounts&.find_by(id: params[:trade_republic_account_id])

    if account.blank? || tr_account.blank?
      redirect_to settings_providers_path, alert: t(".not_found")
      return
    end

    unless account.accountable_type.in?(%w[Investment Depository]) &&
        account.account_providers.none? &&
        account.plaid_account_id.blank? &&
        account.simplefin_account_id.blank?
      redirect_to account_path(account), alert: t(".only_manual_investment")
      return
    end

    provider = nil

    tr_account.with_lock do
      if tr_account.current_account.present?
        redirect_to account_path(account), alert: t(".already_linked")
        return
      end

      provider = tr_account.ensure_account_provider!(account)
    end

    raise "Failed to create AccountProvider link" unless provider

    processing_failed = false
    begin
      TradeRepublicAccount::Processor.new(tr_account.reload).process
    rescue => e
      processing_failed = true
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Failed to process linked Trade Republic account #{tr_account.id}: #{e.class} - #{e.message}",
        source: "trade_republic",
        family: Current.family,
        provider_key: "trade_republic"
      )
    end

    tr_account.trade_republic_item.sync_later unless tr_account.trade_republic_item.syncing?
    if processing_failed
      redirect_to account_path(account), notice: t(".success"), alert: t(".processing_failed"), status: :see_other
    else
      redirect_to account_path(account), notice: t(".success"), status: :see_other
    end
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "Failed to link existing Trade Republic account: #{e.class} - #{e.message}",
      source: "trade_republic",
      family: Current.family,
      provider_key: "trade_republic"
    )
    redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
  end

  def setup_accounts
    @trade_republic_accounts = @trade_republic_item.trade_republic_accounts.includes(account_provider: :account)
    @linked_accounts = @trade_republic_accounts.select { |a| a.current_account.present? }
    @unlinked_accounts = @trade_republic_accounts.reject { |a| a.current_account.present? }

    no_accounts = @linked_accounts.blank? && @unlinked_accounts.blank?
    latest_sync = @trade_republic_item.syncs.ordered.first
    should_sync = latest_sync.nil? || !latest_sync.completed?

    if no_accounts && !@trade_republic_item.syncing? && should_sync && @trade_republic_item.session_configured?
      @trade_republic_item.sync_later
    end

    @linkable_accounts = Current.family.accounts
      .visible
      .where(accountable_type: %w[Investment Depository])
      .left_joins(:account_providers)
      .where(account_providers: { id: nil })
      .order(:name)

    @syncing = @trade_republic_item.syncing?
    @waiting_for_sync = no_accounts && @syncing
    @no_accounts_found = no_accounts && !@syncing && @trade_republic_item.last_synced_at.present?
  end

  def complete_account_setup
    selected_accounts = Array(params[:account_ids]).reject(&:blank?)
    created_accounts = []
    failed_accounts = 0
    failed_processing = 0

    selected_accounts.each do |tr_account_id|
      tr_account = @trade_republic_item.trade_republic_accounts.find_by(id: tr_account_id)
      next unless tr_account

      begin
        tr_account.with_lock do
          next if tr_account.current_account.present?

          account = Account.create_from_trade_republic_account(tr_account)
          provider = tr_account.ensure_account_provider!(account)
          raise ActiveRecord::RecordNotSaved, "Failed to link Trade Republic account" unless provider

          created_accounts << account
        end
      rescue => e
        failed_accounts += 1
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "Failed to create Trade Republic account #{tr_account.id}: #{e.class} - #{e.message}",
          source: "trade_republic",
          family: Current.family,
          provider_key: "trade_republic"
        )
        next
      end

      begin
        TradeRepublicAccount::Processor.new(tr_account.reload).process
      rescue => e
        failed_processing += 1
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "Failed to process Trade Republic account #{tr_account.id} after setup: #{e.class} - #{e.message}",
          source: "trade_republic",
          family: Current.family,
          provider_key: "trade_republic"
        )
      end
    end

    @trade_republic_item.update!(pending_account_setup: @trade_republic_item.unlinked_accounts_count.positive?)
    @trade_republic_item.sync_later if created_accounts.any?

    if created_accounts.any?
      options = { notice: t(".success", count: created_accounts.count), status: :see_other }
      failed_count = failed_accounts + failed_processing
      options[:alert] = t(".partial_failure", count: failed_count) if failed_count.positive?
      redirect_to accounts_path, **options
    elsif selected_accounts.empty?
      redirect_to setup_accounts_trade_republic_item_path(@trade_republic_item), alert: t(".none_selected"), status: :see_other
    else
      message = failed_accounts.positive? ? t(".partial_failure", count: failed_accounts) : t(".none_created")
      redirect_to setup_accounts_trade_republic_item_path(@trade_republic_item), alert: message, status: :see_other
    end
  end

  private

    def initiate_qr_login_for(item)
      result = item.trade_republic_provider.initiate_qr_login
      item.update!(pending_login_state: result.data.fetch("pending_login_b64"), status: :requires_update)
      @qr_code_svg = view_context.generate_mfa_qr_code(result.data["qr_code_payload"]) if result.data["qr_code_payload"].present?
    rescue Provider::TradeRepublicClient::Error => e
      @error_message = e.message
    end

    def set_trade_republic_item
      @trade_republic_item = Current.family.trade_republic_items.find(params[:id])
    end

    def current_trade_republic_item
      active_items = Current.family.trade_republic_items.active
      active_items.syncable.ordered.first || active_items.ordered.first
    end

    def trade_republic_item_params
      params.require(:trade_republic_item).permit(:phone_number, :pin, :currency)
    end

    # Credentials changed → the stored session belongs to the old login.
    def reauthentication_needed?(attrs)
      (attrs["phone_number"].present? && attrs["phone_number"] != @trade_republic_item.phone_number) || attrs["pin"].present?
    end

    def initiate_login_for(item, pin: nil)
      item.update!(session_blob: nil, pending_login_state: nil, status: :requires_update)
      provider = item.trade_republic_provider(pin: pin)
      return unless provider

      result = provider.initiate_login
      item.update!(pending_login_state: result["pending_login_b64"], status: :requires_update)
    rescue Provider::TradeRepublicClient::Error => e
      @error_message = e.message
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "Trade Republic login initiation failed for item #{item.id}: #{e.message}",
        source: "trade_republic",
        family: item.family,
        provider_key: "trade_republic"
      )
    end

    def invalidate_authentication!
      @trade_republic_item.update!(session_blob: nil, pending_login_state: nil, status: :requires_update)
    end

    def redirect_flash_options(success_message)
      @error_message.present? ? { alert: @error_message } : { notice: success_message }
    end

    def trade_republic_login_params
      params.fetch(:trade_republic_login, {}).permit(:code)
    end

    def render_login_panel(alert: nil, notice: nil, success: false)
      if success
        return render turbo_stream: [
          turbo_stream.replace("drawer", view_context.turbo_frame_tag("drawer")),
          turbo_stream.replace(
            "modal",
            render_to_string(partial: "trade_republic_items/connection_success", formats: [ :html ])
          )
        ]
      end

      flash.now[:alert] = alert if alert
      flash.now[:notice] = notice if notice
      render turbo_stream: [
        turbo_stream.replace(
          "trade-republic-providers-panel",
          partial: "settings/providers/trade_republic_panel",
          locals: { trade_republic_item: @trade_republic_item }
        ),
        *flash_notification_stream_items
      ]
    end

    def turbo_panel_request?
      turbo_frame_request? || request.format.turbo_stream?
    end

    def render_panel_error(message)
      @error_message = message

      if turbo_panel_request?
        render turbo_stream: turbo_stream.replace(
          "trade-republic-providers-panel",
          partial: "settings/providers/trade_republic_panel",
          locals: { error_message: @error_message, trade_republic_item: @trade_republic_item }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path(anchor: "trade-republic"), alert: @error_message, status: :see_other
      end
    end

    def render_qr_login_error(error, status: :unprocessable_entity, retryable: false)
      render json: { error: error.message, retryable: retryable }, status: status
    end
end
