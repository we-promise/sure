class BrexItems::AccountSetupsController < ApplicationController
  before_action :require_admin!
  before_action :set_brex_item

  def setup_accounts
    flow = brex_account_flow
    @api_error = flow.import_accounts_with_user_facing_error
    @brex_accounts = flow.unlinked_brex_accounts
    @account_type_options = flow.account_type_options
    @displayable_account_type_options = flow.displayable_account_type_options
    @subtype_options = flow.subtype_options

    render "brex_items/setup_accounts"
  end

  def complete_account_setup
    result = brex_account_flow.complete_setup_result(
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

    def set_brex_item
      @brex_item = Current.family.brex_items.find(params[:id])
    end

    def brex_account_flow
      @brex_account_flow ||= BrexItem::AccountFlow.new(family: Current.family, brex_item: @brex_item)
    end

    def render_accounts_update_after_setup
      @manual_accounts = Account.uncached { Current.family.accounts.visible_manual.order(:name).to_a }
      @brex_items = Current.family.brex_items.ordered

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
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@brex_item),
          partial: "brex_items/brex_item",
          locals: { brex_item: @brex_item }
        )
      ] + Array(flash_notification_stream_items)
    end

    def sanitized_account_types
      supported_types = Provider::BrexAdapter.supported_account_types

      setup_param_hash(:account_types, allowed_account_ids).each_with_object({}) do |(account_id, selected_type), sanitized|
        next unless allowed_account_ids.include?(account_id.to_s)

        normalized_type = selected_type.to_s
        sanitized[account_id.to_s] = supported_types.include?(normalized_type) ? normalized_type : "skip"
      end
    end

    def sanitized_account_subtypes
      allowed_subtypes = (Depository::SUBTYPES.keys + CreditCard::SUBTYPES.keys).map(&:to_s)

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
      @allowed_account_ids ||= @brex_item.brex_accounts.pluck(:id).map(&:to_s)
    end
end
