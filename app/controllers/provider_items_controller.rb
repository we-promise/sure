# Shared controller for an account provider's connections: managing them, and
# selecting and linking their accounts. Each provider routes `<key>_items` to a
# thin `<Key>ItemsController` subclass that names its permitted params in
# #item_params. Views stay the provider's own (`<key>_items/...`) and read
# `@<key>_item` and `@<key>_items`.
class ProviderItemsController < ApplicationController
  ACCOUNT_FLOW_ACTIONS = %i[preload_accounts select_accounts link_accounts select_existing_account link_existing_account].freeze

  before_action :set_item, only: %i[show edit update destroy sync]
  before_action :require_admin!, only: %i[new create edit update destroy sync] + ACCOUNT_FLOW_ACTIONS

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
      @account_flow ||= account_flow_class.new(family: Current.family, item_id: params[:"#{provider_key}_item_id"])
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
end
