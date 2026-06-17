class UpItemsController < ApplicationController
  before_action :set_up_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [
    :new, :create, :preload_accounts, :select_accounts, :link_accounts,
    :select_existing_account, :link_existing_account, :edit, :update,
    :destroy, :sync, :setup_accounts, :complete_account_setup
  ]

  def index
    @up_items = Current.family.up_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def new
    @up_item = Current.family.up_items.build
  end

  def edit
  end

  def create
    @up_item = Current.family.up_items.build(up_item_params)
    @up_item.name = t("up_items.provider_panel.default_connection_name") if @up_item.name.blank?

    if @up_item.save
      @up_item.sync_later
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@up_item.errors.full_messages.join(", "))
    end
  end

  def update
    if @up_item.update(update_params)
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@up_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @up_item.unlink_all!(dry_run: false)
    @up_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  rescue => e
    Rails.logger.warn("Up unlink during destroy failed: #{e.class} - #{e.message}")
    redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
  end

  def sync
    @up_item.sync_later unless @up_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def preload_accounts
    up_item = requested_up_item
    return render json: { success: false, error: "no_credentials", has_accounts: false } unless up_item.credentials_configured?

    error = fetch_up_accounts_from_api(up_item)
    render json: { success: error.blank?, error_message: error, has_accounts: up_item.up_accounts.exists? }
  end

  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    @up_item = requested_up_item

    unless @up_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @api_error = fetch_up_accounts_from_api(@up_item)
    @up_accounts = @up_item.up_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)

    render layout: false
  end

  def link_accounts
    up_item = requested_up_item
    unless up_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    selected_ids = Array(params[:account_ids]).compact_blank
    if selected_ids.empty?
      redirect_to select_accounts_up_items_path(up_item_id: up_item.id, accountable_type: params[:accountable_type], return_to: safe_return_to_path), alert: t(".no_accounts_selected")
      return
    end

    account_type = params[:accountable_type].presence || "Depository"
    unless Provider::UpAdapter.supported_account_types.include?(account_type)
      redirect_to new_account_path, alert: t(".unsupported_account_type")
      return
    end

    created_accounts = []

    ActiveRecord::Base.transaction do
      up_item.up_accounts.where(id: selected_ids).find_each do |up_account|
        next if up_account.account_provider.present?

        account = create_account_from_up(up_account, account_type)
        AccountProvider.create!(account: account, provider: up_account)
        created_accounts << account
      end
    end

    up_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to safe_return_to_path || accounts_path, notice: t(".success", count: created_accounts.count)
    else
      redirect_to select_accounts_up_items_path(up_item_id: up_item.id, accountable_type: account_type, return_to: safe_return_to_path), alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    @up_item = requested_up_item
    unless @up_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @api_error = fetch_up_accounts_from_api(@up_item)
    @up_accounts = @up_item.up_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)
    @return_to = safe_return_to_path

    render layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    up_item = requested_up_item

    unless up_item.credentials_configured?
      redirect_to settings_providers_path, alert: t("up_items.select_existing_account.no_credentials_configured")
      return
    end

    up_account = up_item.up_accounts.find(params[:up_account_id])

    if account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    if up_account.account_provider.present?
      redirect_to accounts_path, alert: t(".up_account_already_linked")
      return
    end

    AccountProvider.create!(account: account, provider: up_account)
    up_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @api_error = fetch_up_accounts_from_api(@up_item)
    @up_accounts = @up_item.up_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)
    @account_type_options = [
      [ t(".account_types.skip"), "skip" ],
      [ t(".account_types.depository"), "Depository" ],
      [ t(".account_types.loan"), "Loan" ]
    ]
    @up_account_type_suggestions = @up_accounts.each_with_object({}) do |up_account, suggestions|
      suggestions[up_account.id] = up_account.suggested_account_type || "skip"
    end
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    created_accounts = []
    skipped_count = 0

    ActiveRecord::Base.transaction do
      account_types.each do |up_account_id, selected_type|
        if selected_type.blank? || selected_type == "skip"
          skipped_count += 1
          next
        end

        next unless Provider::UpAdapter.supported_account_types.include?(selected_type)

        up_account = @up_item.up_accounts.find_by(id: up_account_id)
        next unless up_account
        next if up_account.account_provider.present?

        account = create_account_from_up(up_account, selected_type)
        AccountProvider.create!(account: account, provider: up_account)
        created_accounts << account
      end
    end

    @up_item.sync_later if created_accounts.any?

    flash[:notice] = if created_accounts.any?
      t(".success", count: created_accounts.count)
    elsif skipped_count.positive?
      t(".all_skipped")
    else
      t(".no_accounts")
    end

    redirect_to accounts_path, status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error("Up account setup failed: #{e.class} - #{e.message}")
    redirect_to accounts_path, alert: t(".creation_failed"), status: :see_other
  end

  private

    def set_up_item
      @up_item = Current.family.up_items.find(params[:id])
    end

    def up_item_params
      params.require(:up_item).permit(:name, :sync_start_date, :access_token)
    end

    def update_params
      permitted = up_item_params
      permitted = permitted.except(:access_token) if permitted[:access_token].blank?
      permitted
    end

    def requested_up_item
      Current.family.up_items.active.find_by!(id: params[:up_item_id])
    end

    def fetch_up_accounts_from_api(up_item)
      return t("up_items.setup_accounts.no_credentials") unless up_item.credentials_configured?

      provider = up_item.up_provider
      accounts = provider.get_accounts
      accounts.each do |account_data|
        account = account_data.with_indifferent_access
        account_id = account[:id].presence
        next if account_id.blank? || account[:displayName].blank?

        up_account = up_item.up_accounts.find_or_initialize_by(account_id: account_id.to_s)
        up_account.upsert_up_snapshot!(account)
      end

      nil
    rescue Provider::Up::UpError => e
      Rails.logger.error("Up API error while fetching accounts: #{e.class}: #{e.message}")
      t("up_items.setup_accounts.api_error")
    rescue StandardError => e
      Rails.logger.error("Unexpected error fetching Up accounts: #{e.class}: #{e.message}")
      t("up_items.setup_accounts.api_error")
    end

    def create_account_from_up(up_account, account_type)
      balance = up_account.current_balance || 0
      balance = balance.abs if account_type == "Loan"
      subtype = if account_type == "Depository" && up_account.suggested_account_type == account_type
        up_account.suggested_subtype
      end

      Account.create_and_sync(
        {
          family: Current.family,
          name: up_account.name,
          balance: balance,
          cash_balance: balance,
          currency: up_account.currency || "AUD",
          accountable_type: account_type,
          accountable_attributes: subtype.present? ? { subtype: subtype } : {}
        },
        skip_initial_sync: true
      )
    end

    def render_provider_panel(flash_type, message)
      if turbo_frame_request?
        flash.now[flash_type] = message
        @up_items = Current.family.up_items.active.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "up-providers-panel",
            partial: "settings/providers/up_panel",
            locals: { up_items: @up_items }
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
          "up-providers-panel",
          partial: "settings/providers/up_panel",
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
