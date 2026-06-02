class AkahuItemsController < ApplicationController
  before_action :set_akahu_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [
    :new, :create, :preload_accounts, :select_accounts, :link_accounts,
    :select_existing_account, :link_existing_account, :edit, :update,
    :destroy, :sync, :setup_accounts, :complete_account_setup
  ]

  def index
    @akahu_items = Current.family.akahu_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def new
    @akahu_item = Current.family.akahu_items.build
  end

  def edit
  end

  def create
    @akahu_item = Current.family.akahu_items.build(akahu_item_params)
    @akahu_item.name = t("akahu_items.provider_panel.default_connection_name") if @akahu_item.name.blank?

    if @akahu_item.save
      @akahu_item.sync_later
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@akahu_item.errors.full_messages.join(", "))
    end
  end

  def update
    if @akahu_item.update(update_params)
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@akahu_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @akahu_item.unlink_all!(dry_run: false)
    @akahu_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  rescue => e
    Rails.logger.warn("Akahu unlink during destroy failed: #{e.class} - #{e.message}")
    redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
  end

  def sync
    @akahu_item.sync_later unless @akahu_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def preload_accounts
    akahu_item = requested_akahu_item
    return render json: { success: false, error: "no_credentials", has_accounts: false } unless akahu_item.credentials_configured?

    error = fetch_akahu_accounts_from_api(akahu_item)
    render json: { success: error.blank?, error_message: error, has_accounts: akahu_item.akahu_accounts.exists? }
  end

  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    @akahu_item = requested_akahu_item

    unless @akahu_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @api_error = fetch_akahu_accounts_from_api(@akahu_item)
    @akahu_accounts = @akahu_item.akahu_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)

    render layout: false
  end

  def link_accounts
    akahu_item = requested_akahu_item
    unless akahu_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    selected_ids = Array(params[:account_ids]).compact_blank
    if selected_ids.empty?
      redirect_to select_accounts_akahu_items_path(akahu_item_id: akahu_item.id, accountable_type: params[:accountable_type], return_to: safe_return_to_path), alert: t(".no_accounts_selected")
      return
    end

    account_type = params[:accountable_type].presence || "Depository"
    unless Provider::AkahuAdapter.supported_account_types.include?(account_type)
      redirect_to new_account_path, alert: t(".unsupported_account_type")
      return
    end

    created_accounts = []

    ActiveRecord::Base.transaction do
      akahu_item.akahu_accounts.where(id: selected_ids).find_each do |akahu_account|
        next if akahu_account.account_provider.present?

        account = create_account_from_akahu(akahu_account, account_type)
        AccountProvider.create!(account: account, provider: akahu_account)
        created_accounts << account
      end
    end

    akahu_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to safe_return_to_path || accounts_path, notice: t(".success", count: created_accounts.count)
    else
      redirect_to select_accounts_akahu_items_path(akahu_item_id: akahu_item.id, accountable_type: account_type, return_to: safe_return_to_path), alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    @akahu_item = requested_akahu_item
    unless @akahu_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @api_error = fetch_akahu_accounts_from_api(@akahu_item)
    @akahu_accounts = @akahu_item.akahu_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)
    @return_to = safe_return_to_path

    render layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    akahu_item = requested_akahu_item

    unless akahu_item.credentials_configured?
      redirect_to settings_providers_path, alert: t("akahu_items.select_existing_account.no_credentials_configured")
      return
    end

    akahu_account = akahu_item.akahu_accounts.find(params[:akahu_account_id])

    if account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    if akahu_account.account_provider.present?
      redirect_to accounts_path, alert: t(".akahu_account_already_linked")
      return
    end

    AccountProvider.create!(account: account, provider: akahu_account)
    akahu_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @api_error = fetch_akahu_accounts_from_api(@akahu_item)
    @akahu_accounts = @akahu_item.akahu_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)
    @account_type_options = [
      [ t(".account_types.skip"), "skip" ],
      [ t(".account_types.depository"), "Depository" ],
      [ t(".account_types.credit_card"), "CreditCard" ],
      [ t(".account_types.investment"), "Investment" ],
      [ t(".account_types.loan"), "Loan" ]
    ]
    @akahu_account_type_suggestions = @akahu_accounts.each_with_object({}) do |akahu_account, suggestions|
      suggestions[akahu_account.id] = akahu_account.suggested_account_type || "skip"
    end
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    created_accounts = []
    skipped_count = 0

    ActiveRecord::Base.transaction do
      account_types.each do |akahu_account_id, selected_type|
        if selected_type.blank? || selected_type == "skip"
          skipped_count += 1
          next
        end

        next unless Provider::AkahuAdapter.supported_account_types.include?(selected_type)

        akahu_account = @akahu_item.akahu_accounts.find_by(id: akahu_account_id)
        next unless akahu_account
        next if akahu_account.account_provider.present?

        account = create_account_from_akahu(akahu_account, selected_type)
        AccountProvider.create!(account: account, provider: akahu_account)
        created_accounts << account
      end
    end

    @akahu_item.sync_later if created_accounts.any?

    flash[:notice] = if created_accounts.any?
      t(".success", count: created_accounts.count)
    elsif skipped_count.positive?
      t(".all_skipped")
    else
      t(".no_accounts")
    end

    redirect_to accounts_path, status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error("Akahu account setup failed: #{e.class} - #{e.message}")
    redirect_to accounts_path, alert: t(".creation_failed"), status: :see_other
  end

  private

    def set_akahu_item
      @akahu_item = Current.family.akahu_items.find(params[:id])
    end

    def akahu_item_params
      params.require(:akahu_item).permit(:name, :sync_start_date, :app_token, :user_token)
    end

    def update_params
      permitted = akahu_item_params
      permitted = permitted.except(:app_token) if permitted[:app_token].blank?
      permitted = permitted.except(:user_token) if permitted[:user_token].blank?
      permitted
    end

    def requested_akahu_item
      Current.family.akahu_items.active.find_by!(id: params[:akahu_item_id])
    end

    def fetch_akahu_accounts_from_api(akahu_item)
      return t("akahu_items.setup_accounts.no_credentials") unless akahu_item.credentials_configured?

      provider = akahu_item.akahu_provider
      accounts = provider.get_accounts
      accounts.each do |account_data|
        account = account_data.with_indifferent_access
        account_id = account[:_id].presence || account[:id].presence
        next if account_id.blank? || account[:name].blank?

        akahu_account = akahu_item.akahu_accounts.find_or_initialize_by(account_id: account_id.to_s)
        akahu_account.upsert_akahu_snapshot!(account)
      end

      nil
    rescue Provider::Akahu::AkahuError => e
      Rails.logger.error("Akahu API error while fetching accounts: #{e.class}: #{e.message}")
      t("akahu_items.setup_accounts.api_error")
    rescue StandardError => e
      Rails.logger.error("Unexpected error fetching Akahu accounts: #{e.class}: #{e.message}")
      t("akahu_items.setup_accounts.api_error")
    end

    def create_account_from_akahu(akahu_account, account_type)
      balance = akahu_account.current_balance || 0
      balance = balance.abs if account_type.in?(%w[CreditCard Loan])
      subtype = if account_type == "CreditCard"
        "credit_card"
      elsif account_type == "Depository" && akahu_account.suggested_account_type == account_type
        akahu_account.suggested_subtype
      elsif account_type == "Investment" && akahu_account.suggested_account_type == account_type
        akahu_account.suggested_subtype
      end
      cash_balance = account_type == "Investment" ? 0 : balance

      Account.create_and_sync(
        {
          family: Current.family,
          name: akahu_account.name,
          balance: balance,
          cash_balance: cash_balance,
          currency: akahu_account.currency || "NZD",
          accountable_type: account_type,
          accountable_attributes: subtype.present? ? { subtype: subtype } : {}
        },
        skip_initial_sync: true
      )
    end

    def render_provider_panel(flash_type, message)
      if turbo_frame_request?
        flash.now[flash_type] = message
        @akahu_items = Current.family.akahu_items.active.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "akahu-providers-panel",
            partial: "settings/providers/akahu_panel",
            locals: { akahu_items: @akahu_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, { flash_type => message, status: :see_other }
      end
    end

    def render_provider_panel_error(message)
      @error_message = message
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "akahu-providers-panel",
          partial: "settings/providers/akahu_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end

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

    def encoded_path_separator?(return_to)
      encoded_second_character = return_to[1, 3]
      return false unless encoded_second_character&.start_with?("%")

      decoded = URI.decode_www_form_component(encoded_second_character)
      decoded == "/" || decoded == "\\"
    rescue ArgumentError
      true
    end
end
