# Connections are created, updated and removed from the providers settings panel
# (app/views/settings/providers/_monobank_panel.html.erb), and accounts are linked
# through the dialogs in app/views/monobank_items. There is deliberately no
# index/show/new/edit action: nothing links to them and they would have no template.
class MonobankItemsController < ApplicationController
  before_action :set_monobank_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [
    :create, :preload_accounts, :select_accounts, :link_accounts,
    :select_existing_account, :link_existing_account, :update,
    :destroy, :sync, :setup_accounts, :complete_account_setup
  ]

  # Create a Monobank connection and kick off its first sync.
  def create
    @monobank_item = Current.family.monobank_items.build(monobank_item_params)
    @monobank_item.name = t("monobank_items.provider_panel.default_connection_name") if @monobank_item.name.blank?

    if @monobank_item.save
      @monobank_item.sync_later
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@monobank_item.errors.full_messages.join(", "))
    end
  end

  # Update connection settings (name/token/start date).
  def update
    if @monobank_item.update(update_params)
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@monobank_item.errors.full_messages.join(", "))
    end
  end

  # Unlink all accounts then schedule deletion of the connection.
  def destroy
    results = @monobank_item.unlink_all!(dry_run: false)

    if results.any? { |result| result[:error].present? }
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Monobank unlink during destroy failed",
        source: self.class.name,
        provider_key: "monobank",
        family: @monobank_item.family,
        metadata: { monobank_item_id: @monobank_item.id, failures: results.select { |r| r[:error].present? } }
      )
      redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
      return
    end

    @monobank_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  rescue => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "warn",
      message: "Monobank unlink during destroy failed",
      source: self.class.name,
      provider_key: "monobank",
      family: @monobank_item&.family,
      metadata: { monobank_item_id: @monobank_item&.id, error_class: e.class.name, error_message: e.message }
    )
    redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
  end

  # Trigger a manual sync unless one is already running.
  def sync
    @monobank_item.sync_later unless @monobank_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Fetch accounts from the API (JSON) so the UI can show whether any exist.
  def preload_accounts
    monobank_item = requested_monobank_item
    return render json: { success: false, error: "no_credentials", has_accounts: false } unless monobank_item.credentials_configured?

    error = fetch_monobank_accounts_from_api(monobank_item)
    render json: { success: error.blank?, error_message: error, has_accounts: monobank_item.monobank_accounts.exists? }
  end

  # Render the picker of unlinked Monobank accounts for a new Sure account.
  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    @monobank_item = requested_monobank_item

    unless @monobank_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @api_error = fetch_monobank_accounts_from_api(@monobank_item)
    @monobank_accounts = @monobank_item.monobank_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)

    render layout: false
  end

  # Create new Sure accounts for the selected Monobank accounts and link them.
  def link_accounts
    monobank_item = requested_monobank_item
    unless monobank_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    selected_ids = Array(params[:account_ids]).compact_blank
    if selected_ids.empty?
      redirect_to select_accounts_monobank_items_path(monobank_item_id: monobank_item.id, accountable_type: params[:accountable_type], return_to: safe_return_to_path), alert: t(".no_accounts_selected")
      return
    end

    account_type = params[:accountable_type].presence || "Depository"
    unless Provider::MonobankAdapter.supported_account_types.include?(account_type)
      redirect_to new_account_path, alert: t(".unsupported_account_type")
      return
    end

    created_accounts = []

    ActiveRecord::Base.transaction do
      monobank_item.monobank_accounts.where(id: selected_ids).find_each do |monobank_account|
        next if monobank_account.account_provider.present?

        account = create_account_from_monobank(monobank_account, account_type)
        AccountProvider.create!(account: account, provider: monobank_account)
        created_accounts << account
      end
    end

    monobank_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to safe_return_to_path || accounts_path, notice: t(".success", count: created_accounts.count)
    else
      redirect_to select_accounts_monobank_items_path(monobank_item_id: monobank_item.id, accountable_type: account_type, return_to: safe_return_to_path), alert: t(".link_failed")
    end
  rescue ActiveRecord::RecordNotUnique
    # A concurrent submit linked one of these accounts first; the transaction rolled the
    # whole batch back, so send the user back to the picker rather than a 500.
    redirect_to select_accounts_monobank_items_path(monobank_item_id: monobank_item.id, accountable_type: params[:accountable_type], return_to: safe_return_to_path), alert: t(".link_failed")
  end

  # Render the picker to attach a Monobank account to an existing Sure account.
  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    @monobank_item = requested_monobank_item
    unless @monobank_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @api_error = fetch_monobank_accounts_from_api(@monobank_item)
    @monobank_accounts = @monobank_item.monobank_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)
    @return_to = safe_return_to_path

    render layout: false
  end

  # Link a selected Monobank account to an existing Sure account and sync.
  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    monobank_item = requested_monobank_item

    unless monobank_item.credentials_configured?
      redirect_to settings_providers_path, alert: t("monobank_items.select_existing_account.no_credentials_configured")
      return
    end

    if params[:monobank_account_id].blank?
      redirect_to accounts_path, alert: t(".no_account_selected")
      return
    end

    monobank_account = monobank_item.monobank_accounts.find_by(id: params[:monobank_account_id])
    unless monobank_account
      redirect_to accounts_path, alert: t(".no_account_selected")
      return
    end

    if account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    if monobank_account.account_provider.present?
      redirect_to accounts_path, alert: t(".monobank_account_already_linked")
      return
    end

    begin
      AccountProvider.create!(account: account, provider: monobank_account)
    rescue ActiveRecord::RecordNotUnique
      # The two guards above are reads; a double submit gets both requests past them and
      # the unique indexes on account_providers are what actually settle it. The request
      # that loses that race gets the same answer the guard would have given it.
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    monobank_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name)
  end

  # Render the post-sync setup screen for accounts still needing a decision.
  def setup_accounts
    @api_error = fetch_monobank_accounts_from_api(@monobank_item)
    @monobank_accounts = @monobank_item.monobank_accounts.needs_setup.order(:name)
    @account_type_options = [
      [ t(".account_types.skip"), "skip" ],
      [ t(".account_types.depository"), "Depository" ]
    ]
    @monobank_account_type_suggestions = @monobank_accounts.each_with_object({}) do |monobank_account, suggestions|
      suggestions[monobank_account.id] = monobank_account.suggested_account_type || "skip"
    end
  end

  # Apply the user's per-account setup choices (create/link or skip).
  def complete_account_setup
    account_types = params[:account_types] || {}
    created_accounts = []
    skipped_count = 0

    ActiveRecord::Base.transaction do
      account_types.each do |monobank_account_id, selected_type|
        monobank_account = @monobank_item.monobank_accounts.find_by(id: monobank_account_id)
        next unless monobank_account

        if selected_type.blank? || selected_type == "skip"
          # Persist the skip so the account stops resurfacing as "needs setup" on every sync.
          monobank_account.update!(ignored: true) unless monobank_account.account_provider.present?
          skipped_count += 1
          next
        end

        next unless Provider::MonobankAdapter.supported_account_types.include?(selected_type)
        next if monobank_account.account_provider.present?

        account = create_account_from_monobank(monobank_account, selected_type)
        AccountProvider.create!(account: account, provider: monobank_account)
        created_accounts << account
      end
    end

    @monobank_item.sync_later if created_accounts.any?

    flash[:notice] = if created_accounts.any?
      t(".success", count: created_accounts.count)
    elsif skipped_count.positive?
      t(".all_skipped")
    else
      t(".no_accounts")
    end

    redirect_to accounts_path, status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::RecordNotUnique => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Monobank account setup failed",
      source: self.class.name,
      provider_key: "monobank",
      family: @monobank_item&.family,
      metadata: { monobank_item_id: @monobank_item&.id, error_class: e.class.name, error_message: e.message }
    )
    redirect_to accounts_path, alert: t(".creation_failed"), status: :see_other
  end

  private

    # Load the requested item scoped to the current family.
    def set_monobank_item
      @monobank_item = Current.family.monobank_items.find(params[:id])
    end

    # Strong params for creating/updating a connection.
    def monobank_item_params
      params.require(:monobank_item).permit(:name, :sync_start_date, :access_token)
    end

    # Params for update, dropping a blank token so it isn't overwritten.
    def update_params
      permitted = monobank_item_params
      permitted = permitted.except(:access_token) if permitted[:access_token].blank?
      permitted
    end

    # Load the active item referenced by monobank_item_id, scoped to the family.
    def requested_monobank_item
      Current.family.monobank_items.active.find_by!(id: params[:monobank_item_id])
    end

    # Fetch and upsert account snapshots from the API; returns an error string or nil.
    def fetch_monobank_accounts_from_api(monobank_item)
      return t("monobank_items.setup_accounts.no_credentials") unless monobank_item.credentials_configured?

      provider = monobank_item.monobank_provider
      accounts = provider.get_accounts
      accounts.each do |account_data|
        account = account_data.with_indifferent_access
        account_id = account[:id].presence
        next if account_id.blank?

        monobank_account = monobank_item.monobank_accounts.find_or_initialize_by(account_id: account_id.to_s)
        monobank_account.upsert_monobank_snapshot!(account)
      end

      nil
    # One branch: a Provider::Monobank::Error and an unexpected one produced the same
    # entry and the same message for the user, and error_class already tells them apart
    # in /settings/debug.
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to fetch Monobank accounts",
        source: self.class.name,
        provider_key: "monobank",
        family: monobank_item.family,
        metadata: { monobank_item_id: monobank_item.id, error_class: e.class.name, error_message: e.message }
      )
      t("monobank_items.setup_accounts.api_error")
    end

    # Create and sync a Sure account from a Monobank account snapshot.
    def create_account_from_monobank(monobank_account, account_type)
      # Linking an account clears any prior skip so a future unlink re-prompts for setup.
      monobank_account.update!(ignored: false) if monobank_account.ignored?

      balance = monobank_account.current_balance || 0
      subtype = if account_type == "Depository" && monobank_account.suggested_account_type == account_type
        monobank_account.suggested_subtype
      end

      Account.create_and_sync(
        {
          family: Current.family,
          name: monobank_account.name,
          balance: balance,
          cash_balance: balance,
          currency: monobank_account.currency || "UAH",
          accountable_type: account_type,
          accountable_attributes: subtype.present? ? { subtype: subtype } : {}
        },
        skip_initial_sync: true
      )
    end

    # Re-render the providers settings panel (Turbo) or redirect with a flash.
    def render_provider_panel(flash_type, message)
      if turbo_frame_request?
        flash.now[flash_type] = message
        @monobank_items = Current.family.monobank_items.active.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "monobank-providers-panel",
            partial: "settings/providers/monobank_panel",
            locals: { monobank_items: @monobank_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, { flash_type => message, status: :see_other }
      end
    end

    # Re-render the providers panel with an error (Turbo) or redirect with alert.
    def render_provider_panel_error(message)
      @error_message = message
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "monobank-providers-panel",
          partial: "settings/providers/monobank_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end

    # Validate the return_to param as a safe in-app relative path, or nil.
    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s.strip
      return nil unless return_to.start_with?("/")
      return nil if return_to[1] == "/" || return_to[1] == "\\"
      return nil if return_to.include?("\\") || return_to.match?(/[[:cntrl:]]/)
      return nil if encoded_path_separator?(return_to)

      uri = URI.parse(return_to)
      return nil unless uri.relative?

      Rails.application.routes.recognize_path(uri.path, method: :get)

      return_to
    rescue URI::InvalidURIError, ActionController::RoutingError
      nil
    end

    # True if the path's second char is a percent-encoded slash/backslash
    # (used to block protocol-relative redirect bypasses).
    def encoded_path_separator?(return_to)
      encoded_second_character = return_to[1, 3]
      return false unless encoded_second_character&.start_with?("%")

      decoded = URI.decode_www_form_component(encoded_second_character)
      decoded == "/" || decoded == "\\"
    rescue ArgumentError
      true
    end
end
