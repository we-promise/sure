class TradeRepublicItemsController < ApplicationController
  include TradeRepublicLoginFlow

  before_action :set_trade_republic_item, only: [ :show, :update, :destroy, :sync, :repair, :setup_accounts, :complete_account_setup, :complete_login, :poll_login, :initiate_qr_login, :poll_qr_login, :cancel_qr_login ]
  before_action :require_admin!, only: [ :show, :select_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :repair, :setup_accounts, :complete_account_setup, :complete_login, :poll_login, :initiate_qr_login, :poll_qr_login, :cancel_qr_login ]

  def show
    redirect_to settings_providers_path(anchor: "trade-republic")
  end

  def update
    attrs = trade_republic_item_params.to_h
    # The form leaves the phone number blank to keep the current one.
    attrs.delete("phone_number") if attrs["phone_number"].blank?
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
          replace_card_stream(pin_form_open: @error_message.present?),
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
    # A connection that needs a new login can only fail to sync.
    syncing = @trade_republic_item.syncing?
    queued = @trade_republic_item.ready_for_sync? && !syncing
    @trade_republic_item.sync_later if queued
    if provider_panel_form? && turbo_panel_request?
      # Only this card, as the login steps do, so the other cards keep their state.
      return render_login_panel(notice: (t("settings.providers.sync_provider_in_progress") if queued || syncing))
    end

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
      .select { |tr_account| tr_account.account_provider.nil? && tr_account.linkable_to?(@account) }
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

    unless tr_account.linkable_to?(account) &&
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

    linkable_accounts = Current.family.accounts
      .visible
      .where(accountable_type: %w[Investment Depository Crypto])
      .left_joins(:account_providers)
      .where(account_providers: { id: nil })
      .includes(:accountable)
      .order(:name)
      .to_a
    @linkable_accounts_by_tr_account = @unlinked_accounts.index_with do |tr_account|
      linkable_accounts.select { |linkable| tr_account.linkable_to?(linkable) }
    end

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

    def redirect_flash_options(success_message)
      @error_message.present? ? { alert: @error_message } : { notice: success_message }
    end

    # Push-login polling re-renders about once per second; replacing only this
    # item's card keeps other cards (open state, typed credentials, running QR
    # logins) intact.
    def replace_card_stream(item = @trade_republic_item, pin_form_open: false)
      turbo_stream.replace(
        TradeRepublic::ConnectionCardComponent.dom_id_for(item),
        TradeRepublic::ConnectionCardComponent.new(item: item, qr_active: item.login_stage == "qr_pending", pin_form_open: pin_form_open)
      )
    end

    def other_active_trade_republic_items
      Current.family.trade_republic_items.active.where.not(id: @trade_republic_item.id)
    end

    def discard_duplicate_connection!
      # A failed unique-index write from the losing update! left brokerage_account_id
      # dirty on the in-memory record with the other item's value; clear it
      # explicitly or this update! would collide with the same index again.
      @trade_republic_item.update!(session_blob: nil, pending_login_state: nil, status: :requires_update, brokerage_account_id: nil)
      @trade_republic_item.destroy_later if @trade_republic_item.trade_republic_accounts.none?
    end

    def render_panel_error(message)
      render_provider_panel("trade_republic", alert: message, fallback_path: settings_providers_path(anchor: "trade-republic"))
    end

    # TradeRepublicLoginFlow: the login belongs to this existing connection.
    def login_record
      @trade_republic_item
    end

    def start_qr_login!(pending_login_b64)
      @trade_republic_item.update!(session_blob: nil, pending_login_state: pending_login_b64, status: :requires_update)
    end

    def end_login!(final:)
      @trade_republic_item.update!(pending_login_state: nil, **(final ? { status: :requires_update } : {}))
    end

    def connect_login_record!(result)
      @trade_republic_item.update!(
        session_blob: result.data.fetch("session_txt"),
        pending_login_state: nil,
        status: :good,
        brokerage_account_id: account_id_from(result)
      )
      @trade_republic_item
    end

    def replace_login_record_stream
      replace_card_stream
    end
end
