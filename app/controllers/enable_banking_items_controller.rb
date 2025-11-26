class EnableBankingItemsController < ApplicationController
  before_action :set_enable_banking_item, only: [ :update, :destroy, :sync, :select_bank, :authorize, :reauthorize, :setup_accounts, :complete_account_setup, :new_connection ]
  skip_before_action :verify_authenticity_token, only: [ :callback ]

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
      redirect_url = @enable_banking_item.start_authorization(
        aspsp_name: aspsp_name,
        redirect_url: enable_banking_callback_url,
        state: @enable_banking_item.id
      )

      redirect_to redirect_url, allow_other_host: true
    rescue Provider::EnableBanking::EnableBankingError => e
      Rails.logger.error "Enable Banking authorization error: #{e.message}"
      redirect_to settings_providers_path, alert: t(".authorization_failed", default: "Failed to start authorization: %{message}", message: e.message)
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

  # Create a new connection using credentials from an existing item
  def new_connection
    new_item = Current.family.enable_banking_items.create!(
      name: "Enable Banking Connection",
      country_code: @enable_banking_item.country_code,
      application_id: @enable_banking_item.application_id,
      client_certificate: @enable_banking_item.client_certificate
    )

    redirect_to select_bank_enable_banking_item_path(new_item), data: { turbo_frame: "modal" }
  end

  # Re-authorize an expired session
  def reauthorize
    begin
      redirect_url = @enable_banking_item.start_authorization(
        aspsp_name: @enable_banking_item.aspsp_name,
        redirect_url: enable_banking_callback_url,
        state: @enable_banking_item.id
      )

      redirect_to redirect_url, allow_other_host: true
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

    selected_uids.each do |uid|
      enable_banking_account = enable_banking_item.enable_banking_accounts.find_by(uid: uid)
      next unless enable_banking_account

      # Check if already linked
      if enable_banking_account.account_provider.present?
        already_linked_accounts << enable_banking_account.name
        next
      end

      # Create the internal Account
      account = Account.create_and_sync(
        family: Current.family,
        name: enable_banking_account.name,
        balance: enable_banking_account.current_balance || 0,
        currency: enable_banking_account.currency || "EUR",
        accountable_type: accountable_type,
        accountable_attributes: {}
      )

      # Link account to enable_banking_account via account_providers
      AccountProvider.create!(
        account: account,
        provider: enable_banking_account
      )

      created_accounts << account
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

    # Generate the callback URL for Enable Banking OAuth
    # In production, uses the standard Rails route
    # In development, uses DEV_WEBHOOKS_URL if set (e.g., ngrok URL)
    def enable_banking_callback_url
      return callback_enable_banking_items_url if Rails.env.production?

      ENV.fetch("DEV_WEBHOOKS_URL", root_url.chomp("/")) + "/enable_banking_items/callback"
    end
end
