class EnableBankingItemsController < ApplicationController
  include EnableBankingItems::MapsHelper
  before_action :set_enable_banking_item, only: [ :update, :destroy, :sync, :select_bank, :authorize, :reauthorize, :setup_accounts, :complete_account_setup, :new_connection ]
  skip_before_action :verify_authenticity_token, only: [ :callback ]

  def new
    @enable_banking_item = Current.family.enable_banking_items.build
  end

  def create
    @enable_banking_item = Current.family.enable_banking_items.build(enable_banking_item_params)
    @enable_banking_item.name ||= "Enable Banking Connection"

    if @enable_banking_item.save
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured Enable Banking.")
        @enable_banking_items = Current.family.enable_banking_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "enable_banking-providers-panel",
            partial: "settings/providers/enable_banking_panel",
            locals: { enable_banking_items: @enable_banking_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @enable_banking_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "enable_banking-providers-panel",
          partial: "settings/providers/enable_banking_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @enable_banking_item.update(enable_banking_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated Enable Banking configuration.")
        @enable_banking_items = Current.family.enable_banking_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "enable_banking-providers-panel",
            partial: "settings/providers/enable_banking_panel",
            locals: { enable_banking_items: @enable_banking_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @enable_banking_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "enable_banking-providers-panel",
          partial: "settings/providers/enable_banking_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    # Ensure we detach provider links before scheduling deletion
    begin
      @enable_banking_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("Enable Banking unlink during destroy failed: #{e.class} - #{e.message}")
    end
    @enable_banking_item.revoke_session
    @enable_banking_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled Enable Banking connection for deletion.")
  end

  def sync
    unless @enable_banking_item.syncing?
      @enable_banking_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Show bank selection page
  def select_bank
    unless @enable_banking_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".credentials_required", default: "Please configure your Enable Banking credentials first.")
      return
    end

    # Track if this is for creating a new connection (vs re-authorizing existing)
    @new_connection = params[:new_connection] == "true"

    begin
      provider = @enable_banking_item.enable_banking_provider
      response = provider.get_aspsps(country: @enable_banking_item.country_code)
      # API returns { aspsps: [...] }, extract the array
      @aspsps = response[:aspsps] || response["aspsps"] || []
    rescue Provider::EnableBanking::EnableBankingError => e
      Rails.logger.error "Enable Banking API error in select_bank: #{e.message}"
      @error_message = e.message
      @aspsps = []
    end

    render layout: false
  end

  # Initiate authorization for a selected bank
  def authorize
    aspsp_name = params[:aspsp_name]

    unless aspsp_name.present?
      redirect_to settings_providers_path, alert: t(".bank_required", default: "Please select a bank.")
      return
    end

    begin
      # If this is a new connection request, create the item now (when user has selected a bank)
      target_item = if params[:new_connection] == "true"
        Current.family.enable_banking_items.create!(
          name: "Enable Banking Connection",
          country_code: @enable_banking_item.country_code,
          application_id: @enable_banking_item.application_id,
          client_certificate: @enable_banking_item.client_certificate
        )
      else
        @enable_banking_item
      end

      redirect_url = target_item.start_authorization(
        aspsp_name: aspsp_name,
        redirect_url: enable_banking_callback_url,
        state: target_item.id
      )

      safe_redirect_to_enable_banking(
        redirect_url,
        fallback_path: settings_providers_path,
        fallback_alert: t(".invalid_redirect", default: "Invalid authorization URL received. Please try again.")
      )
    rescue Provider::EnableBanking::EnableBankingError => e
      if e.message.include?("REDIRECT_URI_NOT_ALLOWED")
        Rails.logger.error "Enable Banking redirect URI not allowed: #{e.message}"
        redirect_to settings_providers_path, alert: t(".redirect_uri_not_allowed", default: "Redirect not allowed. Configure `%{callback_url}` in your Enable Banking application settings.", callback_url: enable_banking_callback_url)
      else
        Rails.logger.error "Enable Banking authorization error: #{e.message}"
        redirect_to settings_providers_path, alert: t(".authorization_failed", default: "Failed to start authorization: %{message}", message: e.message)
      end
    rescue => e
      Rails.logger.error "Unexpected error in authorize: #{e.class}: #{e.message}"
      redirect_to settings_providers_path, alert: t(".unexpected_error", default: "An unexpected error occurred. Please try again.")
    end
  end

  # Handle OAuth callback from Enable Banking
  def callback
    code = params[:code]
    state = params[:state]
    error = params[:error]
    error_description = params[:error_description]

    if error.present?
      Rails.logger.error "Enable Banking callback error: #{error} - #{error_description}"
      redirect_to settings_providers_path, alert: t(".authorization_error", default: "Authorization failed: %{error}", error: error_description || error)
      return
    end

    unless code.present? && state.present?
      redirect_to settings_providers_path, alert: t(".invalid_callback", default: "Invalid callback parameters.")
      return
    end

    # Find the enable_banking_item by ID from state
    enable_banking_item = Current.family.enable_banking_items.find_by(id: state)

    unless enable_banking_item.present?
      redirect_to settings_providers_path, alert: t(".item_not_found", default: "Connection not found.")
      return
    end

    begin
      enable_banking_item.complete_authorization(code: code)

      # Trigger sync to process accounts
      enable_banking_item.sync_later

      redirect_to accounts_path, notice: t(".success", default: "Successfully connected to your bank. Your accounts are being synced.")
    rescue Provider::EnableBanking::EnableBankingError => e
      Rails.logger.error "Enable Banking session creation error: #{e.message}"
      redirect_to settings_providers_path, alert: t(".session_failed", default: "Failed to complete authorization: %{message}", message: e.message)
    rescue => e
      Rails.logger.error "Unexpected error in callback: #{e.class}: #{e.message}"
      redirect_to settings_providers_path, alert: t(".unexpected_error", default: "An unexpected error occurred. Please try again.")
    end
  end

  # Show bank selection for a new connection using credentials from an existing item
  # Does NOT create a new item - that happens in authorize when user selects a bank
  def new_connection
    # Redirect to select_bank with a flag indicating this is for a new connection
    redirect_to select_bank_enable_banking_item_path(@enable_banking_item, new_connection: true), data: { turbo_frame: "modal" }
  end

  # Re-authorize an expired session
  def reauthorize
    begin
      redirect_url = @enable_banking_item.start_authorization(
        aspsp_name: @enable_banking_item.aspsp_name,
        redirect_url: enable_banking_callback_url,
        state: @enable_banking_item.id
      )

      safe_redirect_to_enable_banking(
        redirect_url,
        fallback_path: settings_providers_path,
        fallback_alert: t(".invalid_redirect", default: "Invalid authorization URL received. Please try again.")
      )
    rescue Provider::EnableBanking::EnableBankingError => e
      Rails.logger.error "Enable Banking reauthorization error: #{e.message}"
      redirect_to settings_providers_path, alert: t(".reauthorization_failed", default: "Failed to re-authorize: %{message}", message: e.message)
    end
  end

  # Link accounts from Enable Banking to internal accounts
  def link_accounts
    selected_uids = params[:account_uids] || []
    accountable_type = params[:accountable_type] || "Depository"

    if selected_uids.empty?
      redirect_to accounts_path, alert: t(".no_accounts_selected", default: "No accounts selected.")
      return
    end

    enable_banking_item = Current.family.enable_banking_items.where.not(session_id: nil).first

    unless enable_banking_item.present?
      redirect_to settings_providers_path, alert: t(".no_session", default: "No active Enable Banking connection. Please connect a bank first.")
      return
    end

    created_accounts = []
    already_linked_accounts = []

    # Wrap in transaction so partial failures don't leave orphaned accounts without provider links
    begin
      ActiveRecord::Base.transaction do
        selected_uids.each do |uid|
          enable_banking_account = enable_banking_item.enable_banking_accounts.find_by(uid: uid)
          next unless enable_banking_account

          # Check if already linked
          if enable_banking_account.account_provider.present?
            already_linked_accounts << enable_banking_account.name
            next
          end

          # Create the internal Account (uses save! internally, will raise on failure)
          # Skip initial sync - provider sync will handle balance creation with correct currency
          account = Account.create_and_sync(
            {
              family: Current.family,
              name: enable_banking_account.name,
              balance: enable_banking_account.current_balance || 0,
              currency: enable_banking_account.currency || "EUR",
              accountable_type: accountable_type,
              accountable_attributes: {}
            },
            skip_initial_sync: true
          )

          # Link account to enable_banking_account via account_providers
          # Uses create! so any failure will rollback the entire transaction
          AccountProvider.create!(
            account: account,
            provider: enable_banking_account
          )

          created_accounts << account
        end
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error "Enable Banking link_accounts failed: #{e.class} - #{e.message}"
      redirect_to accounts_path, alert: t(".link_failed", default: "Failed to link accounts: %{error}", error: e.message)
      return
    end

    # Trigger sync if accounts were created
    enable_banking_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to accounts_path, notice: t(".success", default: "%{count} account(s) linked successfully.", count: created_accounts.count)
    elsif already_linked_accounts.any?
      redirect_to accounts_path, alert: t(".already_linked", default: "Selected accounts are already linked.")
    else
      redirect_to accounts_path, alert: t(".link_failed", default: "Failed to link accounts.")
    end
  end

  # Show setup accounts modal
  def setup_accounts
    @enable_banking_accounts = @enable_banking_item.enable_banking_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    @account_type_options = [
      [ "Skip this account", "skip" ],
      [ "Checking or Savings Account", "Depository" ],
      [ "Credit Card", "CreditCard" ],
      [ "Investment Account", "Investment" ],
      [ "Loan or Mortgage", "Loan" ],
      [ "Other Asset", "OtherAsset" ]
    ]

    @subtype_options = {
      "Depository" => {
        label: "Account Subtype:",
        options: Depository::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "CreditCard" => {
        label: "",
        options: [],
        message: "Credit cards will be automatically set up as credit card accounts."
      },
      "Investment" => {
        label: "Investment Type:",
        options: Investment::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "Loan" => {
        label: "Loan Type:",
        options: Loan::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "OtherAsset" => {
        label: nil,
        options: [],
        message: "Other assets will be set up as general assets."
      }
    }

    render layout: false
  end

  # Complete account setup from modal
  def complete_account_setup
    account_types = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}

    # Update sync start date from form if provided
    if params[:sync_start_date].present?
      @enable_banking_item.update!(sync_start_date: params[:sync_start_date])
    end

    created_count = 0
    skipped_count = 0

    account_types.each do |enable_banking_account_id, selected_type|
      # Skip accounts marked as "skip"
      if selected_type == "skip" || selected_type.blank?
        skipped_count += 1
        next
      end

      enable_banking_account = @enable_banking_item.enable_banking_accounts.find(enable_banking_account_id)
      selected_subtype = account_subtypes[enable_banking_account_id]

      # Default subtype for CreditCard since it only has one option
      selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

      # Create account with user-selected type and subtype
      account = Account.create_from_enable_banking_account(
        enable_banking_account,
        selected_type,
        selected_subtype
      )

      # Link account via AccountProvider
      AccountProvider.create!(
        account: account,
        provider: enable_banking_account
      )

      created_count += 1
    end

    # Clear pending status and mark as complete
    @enable_banking_item.update!(pending_account_setup: false)

    # Trigger a sync to process the imported data if accounts were created
    @enable_banking_item.sync_later if created_count > 0

    if created_count > 0
      flash[:notice] = t(".success", default: "%{count} account(s) created successfully!", count: created_count)
    elsif skipped_count > 0
      flash[:notice] = t(".all_skipped", default: "All accounts were skipped. You can set them up later from the accounts page.")
    else
      flash[:notice] = t(".no_accounts", default: "No accounts to set up.")
    end

    redirect_to accounts_path, status: :see_other
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    # Filter out Enable Banking accounts that are already linked to any account
    # (either via account_provider or legacy account association)
    @available_enable_banking_accounts = Current.family.enable_banking_items
      .includes(:enable_banking_accounts)
      .flat_map(&:enable_banking_accounts)
      .reject { |sfa| sfa.account_provider.present? || sfa.account.present? }
      .sort_by { |sfa| sfa.updated_at || sfa.created_at }
      .reverse

    # Always render a modal: either choices or a helpful empty-state
    render :select_existing_account, layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    enable_banking_account = EnableBankingAccount.find(params[:enable_banking_account_id])

    # Guard: only manual accounts can be linked (no existing provider links or legacy IDs)
    if @account.account_providers.any? || @account.plaid_account_id.present? || @account.simplefin_account_id.present?
      flash[:alert] = t("enable_banking_items.link_existing_account.errors.only_manual")
      if turbo_frame_request?
        return render turbo_stream: Array(flash_notification_stream_items)
      else
        return redirect_to account_path(@account), alert: flash[:alert]
      end
    end

    # Verify the Enable Banking account belongs to this family's Enable Banking items
    unless enable_banking_account.enable_banking_item.present? &&
           Current.family.enable_banking_items.include?(enable_banking_account.enable_banking_item)
      flash[:alert] = t("enable_banking_items.link_existing_account.errors.invalid_enable_banking_account")
      if turbo_frame_request?
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to account_path(@account), alert: flash[:alert]
      end
      return
    end

    # Relink behavior: detach any legacy link and point provider link at the chosen account
    Account.transaction do
      enable_banking_account.lock!

      # Upsert the AccountProvider mapping deterministically
      ap = AccountProvider.find_or_initialize_by(provider: enable_banking_account)
      previous_account = ap.account
      ap.account_id = @account.id
      ap.save!

      # If the provider was previously linked to a different account in this family,
      # and that account is now orphaned, quietly disable it so it disappears from the
      # visible manual list. This mirrors the unified flow expectation that the provider
      # follows the chosen account.
      if previous_account && previous_account.id != @account.id && previous_account.family_id == @account.family_id
        begin
          # Disabled accounts still appear (greyed-out) in the manual list after a full refresh.
          # Use the app's standard deletion path (async) so the duplicate disappears and the
          # "pending_deletion" state remains truthful in the UI.
          previous_account.destroy_later if previous_account.may_mark_for_deletion?
        rescue => e
          Rails.logger.warn("Failed to cleanup orphaned account #{previous_account.id}: #{e.class} - #{e.message}")
        end
      end
    end

    if turbo_frame_request?
      # Reload the item to ensure associations are fresh
      enable_banking_account.reload
      item = enable_banking_account.enable_banking_item
      item.reload

      # Recompute data needed by Accounts#index partials
      @manual_accounts = Account.uncached {
        Current.family.accounts
          .visible_manual
          .order(:name)
          .to_a
      }
      @enable_banking_items = Current.family.enable_banking_items.ordered.includes(:syncs)
      build_enable_banking_maps_for(@enable_banking_items)

      flash[:notice] = t("enable_banking_items.link_existing_account.success")
      @account.reload
      manual_accounts_stream = if @manual_accounts.any?
        turbo_stream.update(
          "manual-accounts",
          partial: "accounts/index/manual_accounts",
          locals: { accounts: @manual_accounts }
        )
      else
        turbo_stream.replace("manual-accounts", view_context.tag.div(id: "manual-accounts"))
      end

      render turbo_stream: [
        # Optimistic removal of the specific account row if it exists in the DOM
        turbo_stream.remove(ActionView::RecordIdentifier.dom_id(@account)),
        manual_accounts_stream,
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(item),
          partial: "enable_banking_items/enable_banking_item",
          locals: { enable_banking_item: item }
        ),
        turbo_stream.replace("modal", view_context.turbo_frame_tag("modal"))
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path(cache_bust: SecureRandom.hex(6)), notice: t("enable_banking_items.link_existing_account.success"), status: :see_other
    end
  end

  private

    def set_enable_banking_item
      @enable_banking_item = Current.family.enable_banking_items.find(params[:id])
    end

    def enable_banking_item_params
      params.require(:enable_banking_item).permit(
        :name,
        :sync_start_date,
        :country_code,
        :application_id,
        :client_certificate
      )
    end

    def enable_banking_callback_url
      helpers.enable_banking_callback_url
    end

    # Validate redirect URLs from Enable Banking API to prevent open redirect attacks
    # Only allows HTTPS URLs from trusted Enable Banking domains
    TRUSTED_ENABLE_BANKING_HOSTS = %w[
      enablebanking.com
      api.enablebanking.com
      auth.enablebanking.com
    ].freeze

    def valid_enable_banking_redirect_url?(url)
      return false if url.blank?

      begin
        uri = URI.parse(url)

        # Must be HTTPS
        return false unless uri.scheme == "https"

        # Host must be present
        return false if uri.host.blank?

        # Check if host matches or is a subdomain of trusted domains
        TRUSTED_ENABLE_BANKING_HOSTS.any? do |trusted_host|
          uri.host == trusted_host || uri.host.end_with?(".#{trusted_host}")
        end
      rescue URI::InvalidURIError => e
        Rails.logger.warn("Enable Banking invalid redirect URL: #{url.inspect} - #{e.message}")
        false
      end
    end

    def safe_redirect_to_enable_banking(redirect_url, fallback_path:, fallback_alert:)
      if valid_enable_banking_redirect_url?(redirect_url)
        redirect_to redirect_url, allow_other_host: true
      else
        Rails.logger.warn("Enable Banking redirect blocked - invalid URL: #{redirect_url.inspect}")
        redirect_to fallback_path, alert: fallback_alert
      end
    end
end
