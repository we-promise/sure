class OpenBankingIoItemsController < ApplicationController
  before_action :set_open_banking_io_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [
    :create, :select_accounts, :link_accounts,
    :select_existing_account, :link_existing_account, :update,
    :destroy, :sync, :setup_accounts, :complete_account_setup
  ]

  def create
    parsed = OpenBankingIoItem::Credentials.parse(params.dig(:open_banking_io_item, :credentials_json))
    return render_provider_panel_error(credentials_error(parsed)) unless parsed.valid?

    @open_banking_io_item = Current.family.open_banking_io_items.build(create_params.merge(parsed.attributes))
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
      parsed = OpenBankingIoItem::Credentials.parse(params.dig(:open_banking_io_item, :credentials_json))
      return render_provider_panel_error(credentials_error(parsed)) unless parsed.valid?

      credentials = parsed.attributes
    end

    if @open_banking_io_item.update(update_params.merge(credentials))
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@open_banking_io_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    results = @open_banking_io_item.unlink_all!(dry_run: false)

    # If any account failed to unlink, its Holding/AccountProvider rows may still
    # reference the connection. Destroying now would orphan them, so bail out and
    # surface the error instead of scheduling deletion.
    if results.any? { |result| result[:error].present? }
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "open-banking.io unlink during destroy failed",
        source: self.class.name,
        provider_key: "open_banking_io",
        family: @open_banking_io_item.family,
        metadata: { open_banking_io_item_id: @open_banking_io_item.id, failures: results.select { |r| r[:error].present? } }
      )
      redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
      return
    end

    @open_banking_io_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  rescue => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "warn",
      message: "open-banking.io unlink during destroy failed",
      source: self.class.name,
      provider_key: "open_banking_io",
      family: @open_banking_io_item&.family,
      metadata: { open_banking_io_item_id: @open_banking_io_item&.id, error_class: e.class.name, error_message: e.message }
    )
    redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
  end

  def sync
    if @open_banking_io_item.syncing?
      notice = nil
      alert = t(".already_syncing")
    else
      @open_banking_io_item.sync_later
      notice = t(".started")
      alert = nil
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path, notice: notice, alert: alert }
      format.json { head :ok }
    end
  end

  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    @open_banking_io_item = requested_open_banking_io_item

    unless @open_banking_io_item&.credentials_configured?
      render partial: "open_banking_io_items/setup_required", layout: false
      return
    end

    @api_error = @open_banking_io_item.refresh_accounts_from_provider!
    @open_banking_io_accounts = @open_banking_io_item.open_banking_io_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)

    render layout: false
  end

  def link_accounts
    open_banking_io_item = requested_open_banking_io_item
    unless open_banking_io_item&.credentials_configured?
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

    begin
      ActiveRecord::Base.transaction do
        open_banking_io_item.open_banking_io_accounts
                            .where(id: selected_ids)
                            .includes(:account_provider)
                            .find_each do |open_banking_io_account|
          next if open_banking_io_account.account_provider.present?

          account = open_banking_io_account.build_linked_account!(family: Current.family, accountable_type: account_type)
          AccountProvider.create!(account: account, provider: open_banking_io_account)
          created_accounts << account
        end
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      open_banking_io_item.capture_provider_error("Failed to link open-banking.io accounts", error: e)
      redirect_to select_accounts_open_banking_io_items_path(open_banking_io_item_id: open_banking_io_item.id, accountable_type: account_type, return_to: safe_return_to_path), alert: t(".link_failed")
      return
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
    unless @open_banking_io_item&.credentials_configured?
      render partial: "open_banking_io_items/setup_required", layout: false
      return
    end

    @api_error = @open_banking_io_item.refresh_accounts_from_provider!
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

    unless open_banking_io_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    # find_by, not find: a stale modal should get a flash, not a bare 404.
    open_banking_io_account = open_banking_io_item.open_banking_io_accounts.find_by(id: params[:open_banking_io_account_id])
    if open_banking_io_account.nil?
      redirect_to accounts_path, alert: t(".open_banking_io_account_not_found")
      return
    end

    if account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    if open_banking_io_account.account_provider.present?
      redirect_to accounts_path, alert: t(".open_banking_io_account_already_linked")
      return
    end

    begin
      AccountProvider.create!(account: account, provider: open_banking_io_account)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      open_banking_io_item.capture_provider_error("Failed to link an existing account to open-banking.io", error: e)
      redirect_to accounts_path, alert: t(".link_failed")
      return
    end

    open_banking_io_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @api_error = @open_banking_io_item.refresh_accounts_from_provider!
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

        account = open_banking_io_account.build_linked_account!(family: Current.family, accountable_type: selected_type)
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

    def credentials_error(parsed)
      t("open_banking_io_items.provider_panel.#{parsed.error_key}")
    end

    # With an explicit id, that connection or 404. Without one, the family's first
    # credentialed connection -- the account-picker entry point omits the id when the user
    # has not set one up yet, and nil sends them to the credential form.
    def requested_open_banking_io_item
      scope = Current.family.open_banking_io_items.active
      return scope.find_by!(id: params[:open_banking_io_item_id]) if params[:open_banking_io_item_id].present?

      scope.ordered.find(&:credentials_configured?)
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
