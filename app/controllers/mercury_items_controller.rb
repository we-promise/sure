class MercuryItemsController < ApplicationController
  include SafeReturnPath

  before_action :set_mercury_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :new, :create, :preload_accounts, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @mercury_items = Current.family.mercury_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def preload_accounts
    render json: account_flow.preload_payload
  end

  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    result = account_flow.select_accounts_result(accountable_type: @accountable_type)

    return handle_selection_result(result, empty_path: new_account_path, api_return_path: @return_to) unless result.success?

    @mercury_item = result.item
    @available_accounts = result.available_accounts

    render layout: false
  end

  def link_accounts
    result = account_flow.link_new_accounts_result(
      account_ids: params[:account_ids] || [],
      accountable_type: params[:accountable_type] || "Depository"
    )

    redirect_with_navigation(result, return_to: safe_return_to_path)
  end

  def select_existing_account
    return redirect_to accounts_path, alert: t(".no_account_specified") if params[:account_id].blank?

    @account = Current.family.accounts.find_by(id: params[:account_id])
    return redirect_to accounts_path, alert: t(".no_account_specified") unless @account

    result = account_flow.select_existing_account_result(account: @account)

    return handle_selection_result(result, empty_path: accounts_path, api_return_path: accounts_path) unless result.success?

    @mercury_item = result.item
    @available_accounts = result.available_accounts
    @return_to = safe_return_to_path

    render layout: false
  end

  def link_existing_account
    return redirect_to accounts_path, alert: t(".no_account_specified") if params[:account_id].blank?

    account = Current.family.accounts.find_by(id: params[:account_id])
    return redirect_to accounts_path, alert: t(".no_account_specified") unless account

    result = account_flow.link_existing_account_result(account: account, provider_account_id: params[:mercury_account_id])

    redirect_with_navigation(result, return_to: safe_return_to_path)
  end

  def new
    @mercury_item = Current.family.mercury_items.build
  end

  def create
    @mercury_item = Current.family.mercury_items.build(mercury_item_params)
    @mercury_item.name ||= "Mercury Connection"

    if @mercury_item.save
      # Trigger initial sync to fetch accounts
      @mercury_item.sync_later

      redirect_to accounts_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("mercury", alert: @mercury_item.errors.full_messages.join(", "))
    end
  end

  def edit
  end

  def update
    permitted_params = mercury_item_params
    expire_accounts_cache = mercury_accounts_cache_sensitive_update?(permitted_params)

    if @mercury_item.update(permitted_params)
      Rails.cache.delete(mercury_accounts_cache_key(@mercury_item)) if expire_accounts_cache

      render_provider_panel("mercury", notice: t(".success"), fallback_path: accounts_path,
                            mercury_items: Current.family.mercury_items.active.ordered.includes(:syncs, :mercury_accounts))
    else
      render_provider_panel("mercury", alert: @mercury_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    # Ensure we detach provider links before scheduling deletion
    begin
      @mercury_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("Mercury unlink during destroy failed: #{e.class} - #{e.message}")
    end
    @mercury_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    unless @mercury_item.syncing?
      @mercury_item.sync_later
    end
    return render_provider_panel("mercury", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def setup_accounts
    @api_error = account_flow.import_accounts_with_user_facing_error
    @mercury_accounts = account_flow.unlinked_provider_accounts
    @account_type_options = account_flow.account_type_options
    @subtype_options = account_flow.subtype_options
  end

  def complete_account_setup
    result = account_flow.complete_setup_result(
      account_types: sanitized_account_types,
      account_subtypes: sanitized_account_subtypes
    )

    return redirect_to accounts_path, alert: result.message, status: :see_other unless result.success?

    flash[:notice] = result.message

    if turbo_frame_request?
      render_accounts_update_after_setup
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    def render_accounts_update_after_setup
      @manual_accounts = Account.uncached { Current.family.accounts.visible_manual_for(Current.user).order(:name).to_a }
      @mercury_items = Current.family.mercury_items.ordered

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
        manual_accounts_stream,
        # Admin-only action (require_admin!), so the card lists every account.
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@mercury_item),
          partial: "mercury_items/mercury_item",
          locals: { mercury_item: @mercury_item, visible_accounts: @mercury_item.accounts }
        )
      ] + Array(flash_notification_stream_items)
    end

    def sanitized_account_types
      supported_types = MercuryItem::AccountFlow.adapter_class.supported_account_types

      setup_param_hash(:account_types, allowed_account_ids).each_with_object({}) do |(account_id, selected_type), sanitized|
        next unless allowed_account_ids.include?(account_id.to_s)

        normalized_type = selected_type.to_s
        sanitized[account_id.to_s] = supported_types.include?(normalized_type) ? normalized_type : "skip"
      end
    end

    # Subtypes of the account types the provider supports.
    def sanitized_account_subtypes
      allowed_subtypes = MercuryItem::AccountFlow.adapter_class.supported_account_types.flat_map { |type| type.constantize::SUBTYPES.keys }.map(&:to_s)

      setup_param_hash(:account_subtypes, allowed_account_ids).each_with_object({}) do |(account_id, selected_subtype), sanitized|
        next unless allowed_account_ids.include?(account_id.to_s)
        next if selected_subtype.blank?
        next unless allowed_subtypes.include?(selected_subtype.to_s)

        sanitized[account_id.to_s] = selected_subtype.to_s
      end
    end

    def setup_param_hash(key, allowed_keys)
      raw_params = params.fetch(key, {})
      return {} if raw_params.blank?

      if raw_params.is_a?(ActionController::Parameters)
        raw_params.permit(*allowed_keys).to_h
      elsif raw_params.is_a?(Hash)
        raw_params.slice(*allowed_keys)
      else
        {}
      end
    end

    def allowed_account_ids
      @allowed_account_ids ||= @mercury_item.mercury_accounts.pluck(:id).map(&:to_s)
    end

    def account_flow
      @account_flow ||= MercuryItem::AccountFlow.new(family: Current.family, item_id: params[:mercury_item_id], item: @mercury_item)
    end

    def handle_selection_result(result, empty_path:, api_return_path:)
      case result.status
      when :empty, :account_already_linked
        redirect_to empty_path, alert: result.message
      when :no_api_token, :select_connection
        redirect_to settings_providers_path, alert: result.message
      when :setup_required
        if turbo_frame_request?
          render partial: "mercury_items/setup_required", layout: false
        else
          redirect_to settings_providers_path, alert: result.message
        end
      when :api_error, :unexpected_error
        render partial: "mercury_items/api_error", locals: { error_message: result.message, return_path: api_return_path }, layout: false
      else
        redirect_to settings_providers_path, alert: result.message
      end
    end

    def redirect_with_navigation(result, return_to:)
      path = {
        new_account: new_account_path,
        settings_providers: settings_providers_path,
        return_to_or_accounts: return_to || accounts_path
      }.fetch(result.target, accounts_path)

      redirect_to path, result.flash_type => result.message
    end

    def set_mercury_item
      @mercury_item = Current.family.mercury_items.find(params[:id])
    end

    def mercury_item_params
      permitted = params.require(:mercury_item).permit(:name, :sync_start_date, :token, :base_url)
      permitted.delete(:token) if @mercury_item&.persisted? && permitted[:token].blank?
      permitted
    end

    def mercury_accounts_cache_key(mercury_item)
      "mercury_accounts_#{Current.family.id}_#{mercury_item.id}"
    end

    def mercury_accounts_cache_sensitive_update?(permitted_params)
      permitted_params.key?(:token) || permitted_params.key?(:base_url)
    end
end
