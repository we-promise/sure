class AkahuItemsController < ApplicationController
  include RetiredProviderRouting
  self.retired_provider_key = "akahu"
  self.route_live_provider_management = true

  before_action :set_akahu_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [
    :new, :create, :preload_accounts, :select_accounts, :link_accounts,
    :select_existing_account, :link_existing_account, :edit, :update,
    :destroy, :sync, :setup_accounts, :complete_account_setup
  ]
  rescue_from StandardError, with: :render_lifecycle_failure

  def index
    @akahu_items = legacy_akahu_items
    render layout: "settings"
  end

  def show
  end

  def new
    @akahu_item = Current.family.akahu_items.build
  end

  def edit
    AkahuItem::LegacyAccess.with_item(@akahu_item, operation: :lifecycle) { |current| @akahu_item = current }
    redirect_to settings_providers_path, status: :see_other
  end

  def create
    attributes = akahu_item_params.to_h
    attributes["name"] = t("akahu_items.provider_panel.default_connection_name") if attributes["name"].blank?
    @akahu_item = AkahuItem::Lifecycle.create(family: Current.family, actor: Current.user, attributes: attributes)
    if @akahu_item.persisted?
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@akahu_item.errors.full_messages.join(", "))
    end
  end

  def update
    @akahu_item = lifecycle(@akahu_item).update_settings(update_params)
    if @akahu_item.errors.empty?
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@akahu_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    lifecycle(@akahu_item).disconnect(dry_run: false, schedule: true)
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    AkahuItem::SyncRequest.new(item: @akahu_item, actor: Current.user).call

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def preload_accounts
    @akahu_item = requested_akahu_item
    return render json: { success: false, error: "no_credentials", has_accounts: false } unless @akahu_item.credentials_configured?

    result = lifecycle(@akahu_item).discover
    render json: { success: true, error_message: nil, has_accounts: result.fetch(:item).akahu_accounts.exists? }
  end

  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    @akahu_item = requested_akahu_item

    unless @akahu_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    discover_accounts(flow: :link_accounts)

    render layout: false
  end

  def link_accounts
    @akahu_item = requested_akahu_item
    unless @akahu_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    selected_ids = Array(params[:account_ids]).compact_blank
    if selected_ids.empty?
      redirect_to select_accounts_akahu_items_path(akahu_item_id: @akahu_item.id, accountable_type: params[:accountable_type], return_to: safe_return_to_path), alert: t(".no_accounts_selected")
      return
    end

    account_type = params[:accountable_type].presence || "Depository"
    unless Provider::AkahuAdapter.supported_account_types.include?(account_type)
      redirect_to new_account_path, alert: t(".unsupported_account_type")
      return
    end

    result = lifecycle(@akahu_item).link_accounts(account_ids: selected_ids, account_type: account_type,
      selection: selection_from_token(flow: :link_accounts))
    created_accounts = result.fetch(:created_accounts)

    if created_accounts.any?
      redirect_to safe_return_to_path || accounts_path, notice: t(".success", count: created_accounts.count)
    else
      redirect_to select_accounts_akahu_items_path(akahu_item_id: @akahu_item.id, accountable_type: account_type, return_to: safe_return_to_path), alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    @akahu_item = requested_akahu_item
    unless @akahu_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    result = discover_accounts(flow: :link_existing_account, account_id: @account.id)
    if result[:account_already_linked]
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end
    @return_to = safe_return_to_path

    render layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    @akahu_item = requested_akahu_item

    unless @akahu_item.credentials_configured?
      redirect_to settings_providers_path, alert: t("akahu_items.select_existing_account.no_credentials_configured")
      return
    end

    result = lifecycle(@akahu_item).link_existing_account(account_id: account.id, akahu_account_id: params[:akahu_account_id],
      selection: selection_from_token(flow: :link_existing_account, account_id: account.id))
    if result[:error]
      redirect_to accounts_path, alert: t(".#{result.fetch(:error)}")
      return
    end
    account = result.fetch(:account)
    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    discover_accounts(flow: :complete_account_setup, setup: true)
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
    account_types = account_types.to_unsafe_h if account_types.respond_to?(:to_unsafe_h)
    result = lifecycle(@akahu_item).complete_account_setup(account_types: account_types,
      selection: selection_from_token(flow: :complete_account_setup))
    created_accounts = result.fetch(:created_accounts)
    skipped_count = result.fetch(:skipped_count)

    flash[:notice] = if created_accounts.any?
      t(".success", count: created_accounts.count)
    elsif skipped_count.positive?
      t(".all_skipped")
    else
      t(".no_accounts")
    end

    redirect_to accounts_path, status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    capture_lifecycle_failure(e)
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

    def lifecycle(item)
      AkahuItem::Lifecycle.new(item: item, actor: Current.user)
    end

    def selection_from_token(flow:, account_id: nil)
      AkahuItem::Selection.from_token(params[:selection_token], actor: Current.user, flow: flow, account_id: account_id)
    end

    def discover_accounts(**options)
      result = lifecycle(@akahu_item).discover(**options)
      @akahu_item = result.fetch(:item)
      @akahu_accounts = result.fetch(:accounts)
      @selection_token = result[:selection_token]
      result
    end

    def legacy_akahu_items
      Current.family.akahu_items.active.legacy_manageable.ordered
    end

    def render_lifecycle_failure(error)
      # Preserve normal not-found and malformed-request behavior, including
      # foreign-family lookups; do not turn them into successful redirects.
      actions = %w[create edit update destroy sync preload_accounts select_accounts link_accounts
        select_existing_account link_existing_account setup_accounts complete_account_setup]
      unless actions.include?(action_name) && !error.is_a?(ActiveRecord::RecordNotFound) && !error.is_a?(ActionController::ParameterMissing)
        raise error
      end

      capture_lifecycle_failure(error)
      denied = AkahuItem::LegacyAccess::DENIAL_ERRORS.any? { |klass| error.is_a?(klass) }
      status = denied ? :conflict : :service_unavailable
      message = t("akahu_items.lifecycle.unavailable")
      if request.format.json?
        render json: { success: false, error: denied ? "ownership_changed" : "unavailable",
          error_message: message, has_accounts: nil }, status: status
      elsif turbo_frame_request? && action_name.in?(%w[create update])
        render_provider_panel_error(message, status: status)
      else
        redirect_to settings_providers_path, alert: message, status: :see_other
      end
    end

    def capture_lifecycle_failure(error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warning", source: self.class.name,
        provider_key: "akahu", family: Current.family, message: "Akahu connection management failed",
        metadata: { action: action_name, akahu_item_id: @akahu_item&.id, error_class: error.class.name })
    rescue StandardError
      nil
    end

    def render_provider_panel(flash_type, message)
      if turbo_frame_request?
        flash.now[flash_type] = message
        @akahu_items = legacy_akahu_items
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

    def render_provider_panel_error(message, status: :unprocessable_entity)
      @error_message = message
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "akahu-providers-panel",
          partial: "settings/providers/akahu_panel",
          locals: { error_message: @error_message, akahu_items: legacy_akahu_items }
        ), status: status
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
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
