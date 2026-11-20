# Shared controller for an account provider's connections: managing them,
# selecting and linking their accounts, and setting up the accounts they import. Each provider routes `<key>_items` to a
# thin `<Key>ItemsController` subclass that names its permitted params in
# #item_params. Views stay the provider's own (`<key>_items/...`) and read
# `@<key>_item` and `@<key>_items`.
class ProviderItemsController < ApplicationController
  ACCOUNT_FLOW_ACTIONS = %i[preload_accounts select_accounts link_accounts select_existing_account link_existing_account].freeze
  SETUP_ACTIONS = %i[setup_accounts complete_account_setup].freeze

  # Admin check first, so a non-admin gets the same redirect whether or not the
  # connection id exists.
  before_action :require_admin!, only: %i[new create edit update destroy sync] + ACCOUNT_FLOW_ACTIONS + SETUP_ACTIONS
  before_action :set_item, only: %i[show edit update destroy sync] + SETUP_ACTIONS

  def self.connection_declaration
    Provider::Factory.connection_declarations.find { |declaration| declaration[:association].to_s == controller_name } ||
      raise(NotImplementedError, "#{name} serves no declared connection")
  end

  def index
    self.items = family_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def new
    self.item = family_items.build
  end

  def create
    self.item = family_items.build(item_params)
    @item.name = t("#{provider_key}_items.default_connection_name") if @item.name.blank?

    if @item.save
      @item.sync_later
      redirect_to accounts_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel(provider_key, alert: @item.errors.full_messages.join(", "))
    end
  end

  def edit
  end

  def update
    if account_flow_class.update_item_with_cache_expiration(@item, family: Current.family, attributes: item_params)
      render_provider_panel(provider_key, notice: t(".success"), fallback_path: accounts_path,
                            "#{provider_key}_items": family_items.active.ordered.includes(:syncs, declaration[:accounts]))
    else
      render_provider_panel(provider_key, alert: @item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @item.unlink_all!(dry_run: false)
    @item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    @item.sync_later unless @item.syncing?
    return render_provider_panel(provider_key, notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def preload_accounts
    render json: account_flow.preload_payload
  end

  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    result = account_flow.select_accounts_result(accountable_type: @accountable_type)

    return handle_selection_result(result, empty_path: new_account_path, api_return_path: @return_to) unless result.success?

    self.item = result.item
    @available_accounts = result.available_accounts

    render "#{provider_key}_items/select_accounts", layout: false
  end

  def link_accounts
    result = account_flow.link_new_accounts_result(
      account_ids: params[:account_ids] || [],
      accountable_type: params[:accountable_type] || "Depository"
    )

    redirect_with_navigation(result, return_to: safe_return_to_path)
  end

  def select_existing_account
    return redirect_to accounts_path, alert: t("#{provider_key}_items.select_existing_account.no_account_specified") if params[:account_id].blank?

    @account = Current.family.accounts.find_by(id: params[:account_id])
    return redirect_to accounts_path, alert: t("#{provider_key}_items.select_existing_account.no_account_specified") unless @account

    result = account_flow.select_existing_account_result(account: @account)

    return handle_selection_result(result, empty_path: accounts_path, api_return_path: accounts_path) unless result.success?

    self.item = result.item
    @available_accounts = result.available_accounts
    @return_to = safe_return_to_path

    render "#{provider_key}_items/select_existing_account", layout: false
  end

  def link_existing_account
    return redirect_to accounts_path, alert: t("#{provider_key}_items.link_existing_account.no_account_specified") if params[:account_id].blank?

    account = Current.family.accounts.find_by(id: params[:account_id])
    return redirect_to accounts_path, alert: t("#{provider_key}_items.link_existing_account.no_account_specified") unless account

    result = account_flow.link_existing_account_result(
      account: account,
      provider_account_id: params[:"#{provider_key}_account_id"]
    )

    redirect_with_navigation(result, return_to: safe_return_to_path)
  end

  def setup_accounts
    @api_error = account_flow.import_accounts_with_user_facing_error
    instance_variable_set(:"@#{provider_key}_accounts", account_flow.unlinked_provider_accounts)
    @account_type_options = account_flow.account_type_options
    @displayable_account_type_options = account_flow.displayable_account_type_options
    @subtype_options = account_flow.subtype_options

    render "#{provider_key}_items/setup_accounts"
  end

  def complete_account_setup
    result = account_flow.complete_setup_result(
      account_types: sanitized_account_types,
      account_subtypes: sanitized_account_subtypes
    )

    unless result.success?
      redirect_to accounts_path, alert: result.message, status: :see_other
      return
    end

    flash[:notice] = result.message

    if turbo_frame_request?
      render_accounts_update_after_setup
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    # The provider's permitted connection params.
    def item_params
      raise NotImplementedError, "#{self.class.name} must define #item_params"
    end

    def declaration
      @declaration ||= self.class.connection_declaration
    end

    def provider_key
      declaration[:key]
    end

    def account_flow_class
      declaration[:type].constantize::AccountFlow
    end

    def family_items
      Current.family.public_send(declaration[:association])
    end

    def item=(item)
      @item = item
      instance_variable_set(:"@#{provider_key}_item", item)
    end

    def items=(items)
      instance_variable_set(:"@#{provider_key}_items", items)
    end

    def set_item
      self.item = family_items.find(params[:id])
    end

    def account_flow
      @account_flow ||= account_flow_class.new(family: Current.family, item_id: params[:"#{provider_key}_item_id"], item: @item)
    end

    def handle_selection_result(result, empty_path:, api_return_path:)
      case result.status
      when :empty, :account_already_linked
        redirect_to empty_path, alert: result.message
      when :no_api_token, :select_connection
        redirect_to settings_providers_path, alert: result.message
      when :setup_required
        if turbo_frame_request?
          render partial: "#{provider_key}_items/setup_required", layout: false
        else
          redirect_to settings_providers_path, alert: result.message
        end
      when :api_error, :unexpected_error
        render_api_error_partial(result.message, api_return_path)
      else
        redirect_to settings_providers_path, alert: result.message
      end
    end

    def redirect_with_navigation(result, return_to:)
      redirect_to navigation_path_for(result.target, return_to: return_to), result.flash_type => result.message
    end

    def navigation_path_for(target, return_to:)
      {
        new_account: new_account_path,
        settings_providers: settings_providers_path,
        return_to_or_accounts: return_to || accounts_path
      }.fetch(target, accounts_path)
    end

    def render_api_error_partial(error_message, return_path)
      render partial: "#{provider_key}_items/api_error", locals: { error_message: error_message, return_path: return_path }, layout: false
    end

    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s.strip
      return nil unless return_to.start_with?("/")

      second_character = return_to[1]
      return nil if second_character.blank?
      return nil if second_character == "/" || second_character == "\\"
      return nil if second_character.match?(/[[:space:][:cntrl:]]/)
      return nil if encoded_path_separator?(return_to)

      uri = URI.parse(return_to)

      return nil if uri.scheme.present? || uri.host.present?

      return_to
    rescue URI::InvalidURIError
      nil
    end

    def encoded_path_separator?(return_to)
      encoded_second_character = return_to[1, 3]
      return false unless encoded_second_character&.start_with?("%")

      decoded = URI.decode_www_form_component(encoded_second_character)
      decoded == "/" || decoded == "\\"
    rescue ArgumentError
      false
    end

    def render_accounts_update_after_setup
      @manual_accounts = Account.uncached { Current.family.accounts.visible_manual_for(Current.user).order(:name).to_a }
      self.items = family_items.ordered

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
          ActionView::RecordIdentifier.dom_id(@item),
          partial: "#{provider_key}_items/#{provider_key}_item",
          locals: { "#{provider_key}_item": @item, visible_accounts: @item.accounts }
        )
      ] + Array(flash_notification_stream_items)
    end

    def sanitized_account_types
      supported_types = account_flow_class.adapter_class.supported_account_types

      setup_param_hash(:account_types, allowed_account_ids).each_with_object({}) do |(account_id, selected_type), sanitized|
        next unless allowed_account_ids.include?(account_id.to_s)

        normalized_type = selected_type.to_s
        sanitized[account_id.to_s] = supported_types.include?(normalized_type) ? normalized_type : "skip"
      end
    end

    # Subtypes of the account types the provider supports.
    def sanitized_account_subtypes
      allowed_subtypes = account_flow_class.adapter_class.supported_account_types.flat_map { |type| type.constantize::SUBTYPES.keys }.map(&:to_s)

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
      @allowed_account_ids ||= @item.provider_accounts.pluck(:id).map(&:to_s)
    end
end
