class BrexItems::AccountFlowsController < ApplicationController
  before_action :require_admin!

  def preload_accounts
    render json: brex_account_flow.preload_payload
  end

  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    result = brex_account_flow.select_accounts_result(accountable_type: @accountable_type)

    return handle_brex_selection_result(result, empty_path: new_account_path, api_return_path: @return_to) unless result.success?

    @brex_item = result.brex_item
    @available_accounts = result.available_accounts

    render "brex_items/select_accounts", layout: false
  end

  def link_accounts
    result = brex_account_flow.link_new_accounts_result(
      account_ids: params[:account_ids] || [],
      accountable_type: params[:accountable_type] || "Depository"
    )

    redirect_with_navigation(result, return_to: safe_return_to_path)
  end

  def select_existing_account
    return redirect_to accounts_path, alert: t("brex_items.select_existing_account.no_account_specified") if params[:account_id].blank?

    @account = Current.family.accounts.find_by(id: params[:account_id])
    return redirect_to accounts_path, alert: t("brex_items.select_existing_account.no_account_specified") unless @account

    result = brex_account_flow.select_existing_account_result(account: @account)

    return handle_brex_selection_result(result, empty_path: accounts_path, api_return_path: accounts_path) unless result.success?

    @brex_item = result.brex_item
    @available_accounts = result.available_accounts
    @return_to = safe_return_to_path

    render "brex_items/select_existing_account", layout: false
  end

  def link_existing_account
    return redirect_to accounts_path, alert: t("brex_items.link_existing_account.no_account_specified") if params[:account_id].blank?

    account = Current.family.accounts.find_by(id: params[:account_id])
    return redirect_to accounts_path, alert: t("brex_items.link_existing_account.no_account_specified") unless account

    result = brex_account_flow.link_existing_account_result(
      account: account,
      brex_account_id: params[:brex_account_id]
    )

    redirect_with_navigation(result, return_to: safe_return_to_path)
  end

  private

    def brex_account_flow
      @brex_account_flow ||= BrexItem::AccountFlow.new(family: Current.family, brex_item_id: params[:brex_item_id])
    end

    def handle_brex_selection_result(result, empty_path:, api_return_path:)
      case result.status
      when :empty, :account_already_linked
        redirect_to empty_path, alert: result.message
      when :no_api_token, :select_connection
        redirect_to settings_providers_path, alert: result.message
      when :setup_required
        if turbo_frame_request?
          render partial: "brex_items/setup_required", layout: false
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
      render partial: "brex_items/api_error", locals: { error_message: error_message, return_path: return_path }, layout: false
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
