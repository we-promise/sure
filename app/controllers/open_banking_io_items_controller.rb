class OpenBankingIoItemsController < ApplicationController
  before_action :set_open_banking_io_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [
    :new, :create, :preload_accounts, :select_accounts, :link_accounts,
    :select_existing_account, :link_existing_account, :edit, :update,
    :destroy, :sync, :setup_accounts, :complete_account_setup
  ]

  def index
    @open_banking_io_items = Current.family.open_banking_io_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def new
    @open_banking_io_item = Current.family.open_banking_io_items.build
  end

  def edit
  end

  def create
    credentials, parse_error = parse_credentials(params.dig(:open_banking_io_item, :credentials_json))
    return render_provider_panel_error(parse_error) if parse_error

    @open_banking_io_item = Current.family.open_banking_io_items.build(create_params.merge(credentials))
    @open_banking_io_item.name = t("open_banking_io_items.provider_panel.default_connection_name") if @open_banking_io_item.name.blank?

    if @open_banking_io_item.save
      @open_banking_io_item.sync_later
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@open_banking_io_item.errors.full_messages.join(", "))
    end
  end

  def update
    credentials = {}
    if params.dig(:open_banking_io_item, :credentials_json).present?
      credentials, parse_error = parse_credentials(params.dig(:open_banking_io_item, :credentials_json))
      return render_provider_panel_error(parse_error) if parse_error
    end

    if @open_banking_io_item.update(update_params.merge(credentials))
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@open_banking_io_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @open_banking_io_item.unlink_all!(dry_run: false)
    @open_banking_io_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  rescue => e
    Rails.logger.warn("open-banking.io unlink during destroy failed: #{e.class} - #{e.message}")
    redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
  end

  def sync
    @open_banking_io_item.sync_later unless @open_banking_io_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def preload_accounts
    open_banking_io_item = requested_open_banking_io_item
    return render json: { success: false, error: "no_credentials", has_accounts: false } unless open_banking_io_item.credentials_configured?

    error = fetch_open_banking_io_accounts_from_api(open_banking_io_item)
    render json: { success: error.blank?, error_message: error, has_accounts: open_banking_io_item.open_banking_io_accounts.exists? }
  end

  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    @open_banking_io_item = requested_open_banking_io_item

    unless @open_banking_io_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @api_error = fetch_open_banking_io_accounts_from_api(@open_banking_io_item)
    @open_banking_io_accounts = @open_banking_io_item.open_banking_io_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)

    render layout: false
  end

  def link_accounts
    open_banking_io_item = requested_open_banking_io_item
    unless open_banking_io_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    selected_ids = Array(params[:account_ids]).compact_blank
    if selected_ids.empty?
      redirect_to select_accounts_open_banking_io_items_path(open_banking_io_item_id: open_banking_io_item.id, accountable_type: params[:accountable_type], return_to: safe_return_to_path), alert: t(".no_accounts_selected")
      return
    end

    account_type = params[:accountable_type].presence || "Depository"
    unless Provider::OpenBankingIoAdapter.supported_account_types.include?(account_type)
      redirect_to new_account_path, alert: t(".unsupported_account_type")
      return
    end

    created_accounts = []

    ActiveRecord::Base.transaction do
      open_banking_io_item.open_banking_io_accounts.where(id: selected_ids).find_each do |open_banking_io_account|
        next if open_banking_io_account.account_provider.present?

        account = create_account_from_open_banking_io(open_banking_io_account, account_type)
        AccountProvider.create!(account: account, provider: open_banking_io_account)
        created_accounts << account
      end
    end

    open_banking_io_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to safe_return_to_path || accounts_path, notice: t(".success", count: created_accounts.count)
    else
      redirect_to select_accounts_open_banking_io_items_path(open_banking_io_item_id: open_banking_io_item.id, accountable_type: account_type, return_to: safe_return_to_path), alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    @open_banking_io_item = requested_open_banking_io_item
    unless @open_banking_io_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @api_error = fetch_open_banking_io_accounts_from_api(@open_banking_io_item)
    @open_banking_io_accounts = @open_banking_io_item.open_banking_io_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)
    @return_to = safe_return_to_path

    render layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    open_banking_io_item = requested_open_banking_io_item

    unless open_banking_io_item.credentials_configured?
      redirect_to settings_providers_path, alert: t("open_banking_io_items.select_existing_account.no_credentials_configured")
      return
    end

    open_banking_io_account = open_banking_io_item.open_banking_io_accounts.find(params[:open_banking_io_account_id])

    if account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    if open_banking_io_account.account_provider.present?
      redirect_to accounts_path, alert: t(".open_banking_io_account_already_linked")
      return
    end

    AccountProvider.create!(account: account, provider: open_banking_io_account)
    open_banking_io_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @api_error = fetch_open_banking_io_accounts_from_api(@open_banking_io_item)
    @open_banking_io_accounts = @open_banking_io_item.open_banking_io_accounts
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
    @open_banking_io_account_type_suggestions = @open_banking_io_accounts.each_with_object({}) do |open_banking_io_account, suggestions|
      suggestions[open_banking_io_account.id] = open_banking_io_account.suggested_account_type || "skip"
    end
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    created_accounts = []
    skipped_count = 0

    ActiveRecord::Base.transaction do
      account_types.each do |open_banking_io_account_id, selected_type|
        if selected_type.blank? || selected_type == "skip"
          skipped_count += 1
          next
        end

        next unless Provider::OpenBankingIoAdapter.supported_account_types.include?(selected_type)

        open_banking_io_account = @open_banking_io_item.open_banking_io_accounts.find_by(id: open_banking_io_account_id)
        next unless open_banking_io_account
        next if open_banking_io_account.account_provider.present?

        account = create_account_from_open_banking_io(open_banking_io_account, selected_type)
        AccountProvider.create!(account: account, provider: open_banking_io_account)
        created_accounts << account
      end
    end

    @open_banking_io_item.sync_later if created_accounts.any?

    flash[:notice] = if created_accounts.any?
      t(".success", count: created_accounts.count)
    elsif skipped_count.positive?
      t(".all_skipped")
    else
      t(".no_accounts")
    end

    redirect_to accounts_path, status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error("open-banking.io account setup failed: #{e.class} - #{e.message}")
    redirect_to accounts_path, alert: t(".creation_failed"), status: :see_other
  end

  private

    def set_open_banking_io_item
      @open_banking_io_item = Current.family.open_banking_io_items.find(params[:id])
    end

    def create_params
      params.require(:open_banking_io_item).permit(:name, :sync_start_date)
    end

    def update_params
      params.require(:open_banking_io_item).permit(:name, :sync_start_date)
    end

    # Parses the exported credentials.json bundle pasted by the user, extracting
    # the fields the item stores. Returns [credentials_hash, error_message].
    def parse_credentials(raw_json)
      return [ {}, t("open_banking_io_items.provider_panel.credentials_required") ] if raw_json.blank?

      bundle = JSON.parse(raw_json)
      api_base_url = bundle["apiBaseUrl"].presence
      api_key = bundle["apiKey"].presence
      private_key = bundle.dig("encryptionKey", "privateKey").presence ||
                    bundle.dig("encryptionKey", "privateKeyPkcs8B64").presence

      if api_base_url.blank? || api_key.blank? || private_key.blank?
        return [ {}, t("open_banking_io_items.provider_panel.credentials_invalid") ]
      end

      [ { api_base_url: api_base_url, api_key: api_key, private_key: private_key }, nil ]
    rescue JSON::ParserError
      [ {}, t("open_banking_io_items.provider_panel.credentials_invalid") ]
    end

    def requested_open_banking_io_item
      Current.family.open_banking_io_items.active.find_by!(id: params[:open_banking_io_item_id])
    end

    def fetch_open_banking_io_accounts_from_api(open_banking_io_item)
      return t("open_banking_io_items.setup_accounts.no_credentials") unless open_banking_io_item.credentials_configured?

      provider = open_banking_io_item.open_banking_io_provider
      accounts = provider.get_accounts
      accounts.each do |account_data|
        account = account_data.with_indifferent_access
        account_id = account[:id].presence
        next if account_id.blank?

        open_banking_io_account = open_banking_io_item.open_banking_io_accounts.find_or_initialize_by(account_id: account_id.to_s)
        open_banking_io_account.upsert_open_banking_io_snapshot!(account)
      end

      nil
    rescue Provider::OpenBankingIo::Error => e
      Rails.logger.error("open-banking.io API error while fetching accounts: #{e.class}: #{e.message}")
      t("open_banking_io_items.setup_accounts.api_error")
    rescue StandardError => e
      Rails.logger.error("Unexpected error fetching open-banking.io accounts: #{e.class}: #{e.message}")
      t("open_banking_io_items.setup_accounts.api_error")
    end

    def create_account_from_open_banking_io(open_banking_io_account, account_type)
      balance = open_banking_io_account.current_balance || 0
      balance = balance.abs if account_type.in?(%w[CreditCard Loan])
      subtype = if account_type == "CreditCard"
        "credit_card"
      elsif account_type == "Depository" && open_banking_io_account.suggested_account_type == account_type
        open_banking_io_account.suggested_subtype
      elsif account_type == "Investment" && open_banking_io_account.suggested_account_type == account_type
        open_banking_io_account.suggested_subtype
      end
      cash_balance = account_type == "Investment" ? 0 : balance

      Account.create_and_sync(
        {
          family: Current.family,
          name: open_banking_io_account.name,
          balance: balance,
          cash_balance: cash_balance,
          currency: open_banking_io_account.currency || "EUR",
          accountable_type: account_type,
          accountable_attributes: subtype.present? ? { subtype: subtype } : {}
        },
        skip_initial_sync: true
      )
    end

    def render_provider_panel(flash_type, message)
      if turbo_frame_request?
        flash.now[flash_type] = message
        @open_banking_io_items = Current.family.open_banking_io_items.active.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "open_banking_io-providers-panel",
            partial: "settings/providers/open_banking_io_panel",
            locals: { open_banking_io_items: @open_banking_io_items }
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
          "open_banking_io-providers-panel",
          partial: "settings/providers/open_banking_io_panel",
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
