class LunchflowItemsController < ApplicationController
  include SafeReturnPath

  before_action :set_lunchflow_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :new, :create, :preload_accounts, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @lunchflow_items = Current.family.lunchflow_items.active.ordered
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

    @lunchflow_item = result.item
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

    @lunchflow_item = result.item
    @available_accounts = result.available_accounts
    @return_to = safe_return_to_path

    render layout: false
  end

  def link_existing_account
    return redirect_to accounts_path, alert: t(".no_account_specified") if params[:account_id].blank?

    account = Current.family.accounts.find_by(id: params[:account_id])
    return redirect_to accounts_path, alert: t(".no_account_specified") unless account

    result = account_flow.link_existing_account_result(account: account, provider_account_id: params[:lunchflow_account_id])

    redirect_with_navigation(result, return_to: safe_return_to_path)
  end

  def new
    @lunchflow_item = Current.family.lunchflow_items.build
  end

  def create
    @lunchflow_item = Current.family.lunchflow_items.build(lunchflow_params)
    @lunchflow_item.name = t("lunchflow_items.default_connection_name") if @lunchflow_item.name.blank?

    if @lunchflow_item.save
      @lunchflow_item.sync_later

      redirect_to accounts_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("lunchflow", alert: @lunchflow_item.errors.full_messages.join(", "))
    end
  end

  def edit
  end

  def update
    if LunchflowItem::AccountFlow.update_item_with_cache_expiration(@lunchflow_item, family: Current.family, attributes: lunchflow_params)
      render_provider_panel("lunchflow", notice: t(".success"), fallback_path: accounts_path,
                            lunchflow_items: Current.family.lunchflow_items.active.ordered.includes(:syncs, :lunchflow_accounts))
    else
      render_provider_panel("lunchflow", alert: @lunchflow_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @lunchflow_item.unlink_all!(dry_run: false)
    @lunchflow_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    @lunchflow_item.sync_later unless @lunchflow_item.syncing?
    return render_provider_panel("lunchflow", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def setup_accounts
    @api_error = account_flow.import_accounts_with_user_facing_error
    @lunchflow_accounts = account_flow.unlinked_provider_accounts
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
      @lunchflow_items = Current.family.lunchflow_items.ordered

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
          ActionView::RecordIdentifier.dom_id(@lunchflow_item),
          partial: "lunchflow_items/lunchflow_item",
          locals: { lunchflow_item: @lunchflow_item, visible_accounts: @lunchflow_item.accounts }
        )
      ] + Array(flash_notification_stream_items)
    end

    def sanitized_account_types
      supported_types = LunchflowItem::AccountFlow.adapter_class.supported_account_types

      setup_param_hash(:account_types, allowed_account_ids).each_with_object({}) do |(account_id, selected_type), sanitized|
        next unless allowed_account_ids.include?(account_id.to_s)

        normalized_type = selected_type.to_s
        sanitized[account_id.to_s] = supported_types.include?(normalized_type) ? normalized_type : "skip"
      end
    end

    # Subtypes of the account types the provider supports.
    def sanitized_account_subtypes
      allowed_subtypes = LunchflowItem::AccountFlow.adapter_class.supported_account_types.flat_map { |type| type.constantize::SUBTYPES.keys }.map(&:to_s)

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
      @allowed_account_ids ||= @lunchflow_item.lunchflow_accounts.pluck(:id).map(&:to_s)
    end

    def account_flow
      @account_flow ||= LunchflowItem::AccountFlow.new(family: Current.family, item_id: params[:lunchflow_item_id], item: @lunchflow_item)
    end

    def handle_selection_result(result, empty_path:, api_return_path:)
      case result.status
      when :empty, :account_already_linked
        redirect_to empty_path, alert: result.message
      when :no_api_token, :select_connection
        redirect_to settings_providers_path, alert: result.message
      when :setup_required
        if turbo_frame_request?
          render partial: "lunchflow_items/setup_required", layout: false
        else
          redirect_to settings_providers_path, alert: result.message
        end
      when :api_error, :unexpected_error
        render partial: "lunchflow_items/api_error", locals: { error_message: result.message, return_path: api_return_path }, layout: false
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

    def set_lunchflow_item
      @lunchflow_item = Current.family.lunchflow_items.find(params[:id])
    end

    def lunchflow_params
      params.require(:lunchflow_item).permit(:name, :sync_start_date, :api_key, :base_url)
    end
end
