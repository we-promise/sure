# frozen_string_literal: true

class CoinspotItemsController < ApplicationController
  before_action :set_coinspot_item, only: %i[update destroy sync setup_accounts complete_account_setup]
  before_action :require_admin!, only: %i[create select_accounts link_accounts select_existing_account link_existing_account update destroy sync setup_accounts complete_account_setup]

  # Creates a new CoinSpot connection from the settings panel form, sets its
  # institution branding, and queues the first sync.
  def create
    @coinspot_item = Current.family.coinspot_items.build(coinspot_item_params)
    @coinspot_item.name ||= t(".default_name")

    if @coinspot_item.save
      @coinspot_item.set_coinspot_institution_defaults!
      @coinspot_item.sync_later
      render_panel_success(t(".success"))
    else
      render_panel_error(@coinspot_item.errors.full_messages.join(", "))
    end
  end

  # Updates a connection's editable fields (name, sync start date, and
  # optionally new credentials).
  def update
    if @coinspot_item.update(coinspot_item_params)
      render_panel_success(t(".success"))
    else
      render_panel_error(@coinspot_item.errors.full_messages.join(", "))
    end
  end

  # Unlinks every account from this connection, then schedules the
  # connection itself for asynchronous deletion.
  def destroy
    @coinspot_item.unlink_all!(dry_run: false)
    @coinspot_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  # Queues a manual sync, unless one is already running.
  def sync
    @coinspot_item.sync_later unless @coinspot_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to settings_providers_path }
      format.json { head :ok }
    end
  end

  # Entry point for adding a new CoinSpot-backed account: resolves which
  # connection to use (from the param, or the family's only credentialed
  # one) and redirects into account setup, or back with a selection prompt
  # when the connection is ambiguous or missing.
  def select_accounts
    account_flow = coinspot_item_account_flow_context
    coinspot_item = account_flow[:coinspot_item]

    unless coinspot_item
      redirect_to settings_providers_path, alert: coinspot_item_selection_message(account_flow[:credentialed_items])
      return
    end

    redirect_to setup_accounts_coinspot_item_path(coinspot_item, return_to: safe_return_to_path), status: :see_other
  end

  # Entry point for linking an already-existing manual account to a CoinSpot
  # connection: resolves the connection and redirects into account setup.
  def link_accounts
    coinspot_item = coinspot_item_account_flow_context[:coinspot_item]
    unless coinspot_item
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    redirect_to setup_accounts_coinspot_item_path(coinspot_item), status: :see_other
  end

  # Renders the dialog for picking which unlinked CoinSpot account to attach
  # to an existing manual Crypto exchange account.
  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    account_flow = coinspot_item_account_flow_context
    @coinspot_item = account_flow[:coinspot_item]

    unless manual_crypto_exchange_account?(@account)
      redirect_to accounts_path, alert: t("coinspot_items.link_existing_account.errors.only_manual")
      return
    end

    unless @coinspot_item
      redirect_to settings_providers_path, alert: coinspot_item_selection_message(account_flow[:credentialed_items])
      return
    end

    @available_coinspot_accounts = @coinspot_item.coinspot_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)

    render :select_existing_account, layout: false
  end

  # Links a chosen unlinked CoinSpot account to an existing manual account
  # and queues a sync so its history imports immediately.
  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    coinspot_item = coinspot_item_account_flow_context[:coinspot_item]

    unless manual_crypto_exchange_account?(@account)
      return redirect_or_flash_error(t(".errors.only_manual"), account_path(@account))
    end

    unless coinspot_item
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    coinspot_account = coinspot_item.coinspot_accounts.find_by(id: params[:coinspot_account_id])
    unless coinspot_account
      return redirect_or_flash_error(t(".errors.invalid_coinspot_account"), account_path(@account))
    end
    if coinspot_account.account_provider.present?
      return redirect_or_flash_error(t(".errors.coinspot_account_already_linked"), account_path(@account))
    end

    AccountProvider.create!(account: @account, provider: coinspot_account)
    coinspot_item.sync_later

    redirect_to accounts_path, notice: t(".success")
  end

  # Renders the dialog listing this connection's not-yet-imported accounts
  # for the user to select from.
  def setup_accounts
    @coinspot_accounts = unlinked_accounts_for(@coinspot_item)
  end

  # Creates a Sure account for each selected, still-unlinked CoinSpot
  # account and processes its initial activity. A single account's failure
  # is logged and skipped rather than aborting the rest of the selection;
  # a created account whose provider link fails to save is torn back down
  # instead of left half-set-up.
  def complete_account_setup
    selected_accounts = Array(params[:selected_accounts]).reject(&:blank?)
    created_accounts = []
    failed_accounts = 0

    selected_accounts.each do |coinspot_account_id|
      coinspot_account = @coinspot_item.coinspot_accounts.find_by(id: coinspot_account_id)
      next unless coinspot_account

      coinspot_account.with_lock do
        next if coinspot_account.account_provider.present?

        account = Account.create_from_coinspot_account(coinspot_account)
        provider_link = coinspot_account.ensure_account_provider!(account)
        provider_link ? created_accounts << account : account.destroy!
      end

      CoinspotAccount::Processor.new(coinspot_account.reload).process
    rescue StandardError => e
      failed_accounts += 1
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to setup account for CoinspotAccount: #{e.message}",
        source: self.class.name,
        provider_key: "coinspot",
        family: @coinspot_item.family,
        metadata: { coinspot_account_id: coinspot_account_id, error_class: e.class.name }
      )
    end

    @coinspot_item.update!(pending_account_setup: unlinked_accounts_for(@coinspot_item).exists?)
    @coinspot_item.sync_later if created_accounts.any?

    notice = if created_accounts.any?
      t(".success", count: created_accounts.count)
    elsif selected_accounts.empty?
      t(".none_selected")
    elsif failed_accounts == selected_accounts.count
      t(".setup_failed", count: failed_accounts)
    else
      t(".no_accounts")
    end

    redirect_to accounts_path, notice: notice, status: :see_other
  end

  private

    # Loads the connection scoped to the current family, 404ing if it
    # doesn't belong to them.
    def set_coinspot_item
      @coinspot_item = Current.family.coinspot_items.find(params[:id])
    end

    # Permitted connection attributes. Blank credential fields are dropped
    # on update so re-submitting the edit form without touching them doesn't
    # overwrite already-stored credentials with blanks.
    def coinspot_item_params
      permitted = params.require(:coinspot_item).permit(:name, :sync_start_date, :api_key, :api_secret)
      if @coinspot_item&.persisted?
        permitted.delete(:api_key) if permitted[:api_key].blank?
        permitted.delete(:api_secret) if permitted[:api_secret].blank?
      end
      permitted
    end

    # Reports a settings-panel action's success: a Turbo Stream update for a
    # frame request, or a full-page redirect otherwise.
    def render_panel_success(message)
      if turbo_frame_request?
        flash.now[:notice] = message
        @coinspot_items = Current.family.coinspot_items.active.ordered
        stream = turbo_stream.update(
          "coinspot-providers-panel",
          partial: "settings/providers/coinspot_panel",
          locals: { coinspot_items: @coinspot_items }
        )
        render turbo_stream: [ stream, *flash_notification_stream_items ]
      else
        redirect_to settings_providers_path, notice: message, status: :see_other
      end
    end

    # Reports a settings-panel action's failure: a Turbo Stream replace for a
    # frame request, or a full-page redirect with an alert otherwise.
    def render_panel_error(message)
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "coinspot-providers-panel",
          partial: "settings/providers/coinspot_panel",
          locals: { error_message: message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: message, status: :see_other
      end
    end

    # Resolves which connection an account-linking flow should act on: the
    # one named by params[:coinspot_item_id], or the family's only
    # credentialed connection when there's exactly one and no id was given.
    # Also returns every credentialed connection, for the selection prompt
    # when the target is ambiguous.
    def coinspot_item_account_flow_context
      credentialed_items = Current.family.coinspot_items.active.credentials_configured.ordered.select(&:credentials_configured?)
      item = if params[:coinspot_item_id].present?
        credentialed_items.find { |candidate| candidate.id.to_s == params[:coinspot_item_id].to_s }
      elsif credentialed_items.one?
        credentialed_items.first
      end

      { coinspot_item: item, credentialed_items: credentialed_items }
    end

    # A connection's CoinSpot accounts not yet linked to a Sure account.
    def unlinked_accounts_for(coinspot_item)
      coinspot_item.coinspot_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).order(:name)
    end

    # Explains why no connection could be resolved: ambiguous (multiple
    # connections, none specified) versus none configured at all.
    def coinspot_item_selection_message(credentialed_items)
      if credentialed_items.count > 1 && params[:coinspot_item_id].blank?
        t("coinspot_items.select_accounts.select_connection")
      else
        t("coinspot_items.select_accounts.no_credentials_configured")
      end
    end

    # Only a manual Crypto exchange account with no existing provider link
    # is eligible to be linked to a CoinSpot account.
    def manual_crypto_exchange_account?(account)
      account.manual_crypto_exchange?
    end

    # Reports an error from a linking action: a flash Turbo Stream for a
    # frame request, or a redirect with an alert otherwise.
    def redirect_or_flash_error(message, fallback_path)
      if turbo_frame_request?
        flash.now[:alert] = message
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to fallback_path, alert: message
      end
    end

    # Validates params[:return_to] is a same-origin relative path before
    # using it as a redirect target, rejecting anything with a scheme or
    # host (open-redirect protection) or that doesn't start with "/".
    def safe_return_to_path
      return nil if params[:return_to].blank?

      value = params[:return_to].to_s
      uri = URI.parse(value)
      return nil if uri.scheme.present?
      return nil if uri.host.present?
      return nil unless value.start_with?("/")

      value
    rescue URI::InvalidURIError
      nil
    end
end
