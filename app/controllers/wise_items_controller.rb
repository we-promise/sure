# frozen_string_literal: true

class WiseItemsController < ApplicationController
  before_action :set_wise_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :create, :update, :destroy, :sync, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :setup_accounts, :complete_account_setup ]

  def index
    @wise_items = Current.family.wise_items.ordered
  end

  def new
    @wise_item = Current.family.wise_items.build
  end

  def create
    @wise_item = Current.family.wise_items.build(wise_item_params)
    @wise_item.name = I18n.t("wise_items.default_name") if @wise_item.name.blank?

    if @wise_item.save
      @wise_item.sync_later unless @wise_item.syncing?

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @wise_items = Current.family.wise_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "wise-providers-panel",
            partial: "settings/providers/wise_panel",
            locals: { wise_items: @wise_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @wise_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "wise-providers-panel",
          partial: "settings/providers/wise_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message
      end
    end
  end

  def update
    update_attrs = update_params
    update_attrs = update_attrs.merge(status: :good) if update_attrs[:api_token].present?

    if @wise_item.update(update_attrs)
      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @wise_items = Current.family.wise_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "wise-providers-panel",
            partial: "settings/providers/wise_panel",
            locals: { wise_items: @wise_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @wise_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "wise-providers-panel",
          partial: "settings/providers/wise_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message
      end
    end
  end

  def destroy
    @wise_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    unless @wise_item.syncing?
      @wise_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    wise_item = Current.family.wise_items.first

    unless wise_item&.credentials_configured?
      if turbo_frame_request?
        render partial: "wise_items/setup_required", layout: false
      else
        redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      end
      return
    end

    redirect_to setup_accounts_wise_item_path(wise_item, return_to: safe_return_to_path)
  end

  def link_accounts
    wise_item = Current.family.wise_items.first

    unless wise_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_token")
      return
    end

    selected_ids = params[:selected_account_ids] || []
    if selected_ids.empty?
      redirect_to select_accounts_wise_items_path, alert: t(".no_accounts_selected")
      return
    end

    accountable_type = params[:accountable_type] || "Depository"
    created_count = 0
    already_linked_count = 0
    invalid_count = 0

    wise_item.wise_accounts.where(id: selected_ids).find_each do |wise_account|
      if wise_account.account_provider.present?
        already_linked_count += 1
        next
      end

      if wise_account.name.blank?
        invalid_count += 1
        next
      end

      wise_account.provision_account!(family: Current.family, accountable_type: accountable_type)
      created_count += 1
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to link Wise account",
        source: "WiseItemsController",
        provider_key: "wise",
        family: Current.family,
        metadata: { wise_account_id: wise_account.id, error_class: e.class.name, error_message: e.message }
      )
      invalid_count += 1
    end

    if created_count > 0
      wise_item.sync_later unless wise_item.syncing?
      if invalid_count > 0
        redirect_to accounts_path, notice: t(".partial_invalid", created_count: created_count, already_linked_count: already_linked_count, invalid_count: invalid_count)
      elsif already_linked_count > 0
        redirect_to accounts_path, notice: t(".partial_success", created_count: created_count, already_linked_count: already_linked_count)
      else
        redirect_to accounts_path, notice: t(".success", count: created_count)
      end
    elsif already_linked_count > 0 && created_count == 0
      redirect_to select_accounts_wise_items_path, alert: t(".all_already_linked", count: already_linked_count)
    else
      redirect_to select_accounts_wise_items_path, alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account    = find_writable_account!(params[:account_id])
    @wise_item  = Current.family.wise_items.first

    unless @wise_item&.credentials_configured?
      if turbo_frame_request?
        render partial: "wise_items/setup_required", layout: false
      else
        redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      end
      return
    end

    @wise_accounts = @wise_item.wise_accounts
                               .left_joins(:account_provider)
                               .where(account_providers: { id: nil })
                               .order(:name)
  end

  def link_existing_account
    account   = find_writable_account!(params[:account_id])
    wise_item = Current.family.wise_items.first

    unless wise_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_token")
      return
    end

    wise_account = wise_item.wise_accounts.find(params[:wise_account_id])

    if wise_account.account_provider.present?
      redirect_to account_path(account), alert: t(".provider_account_already_linked")
      return
    end

    ActiveRecord::Base.transaction do
      wise_account.ensure_account_provider!(account)
    end
    wise_item.sync_later unless wise_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @unlinked_accounts = @wise_item.unlinked_wise_accounts.order(:name)
  end

  def complete_account_setup
    account_configs = params[:accounts] || {}

    if account_configs.empty?
      redirect_to setup_accounts_wise_item_path(@wise_item), alert: t(".no_accounts")
      return
    end

    created_count = 0
    skipped_count = 0

    account_configs.each do |wise_account_id, config|
      next if config[:account_type] == "skip"

      wise_account = @wise_item.wise_accounts.find_by(id: wise_account_id)
      next unless wise_account
      next if wise_account.account_provider.present?

      accountable_type = config[:account_type].present? ? infer_accountable_type(config[:account_type]) : "Depository"

      ActiveRecord::Base.transaction do
        wise_account.provision_account!(
          family: Current.family,
          accountable_type: accountable_type,
          balance: config[:balance].presence&.to_d
        )
        wise_account.update!(sync_start_date: config[:sync_start_date]) if config[:sync_start_date].present?
      end
      created_count += 1
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to create account during Wise setup",
        source: "WiseItemsController",
        provider_key: "wise",
        family: Current.family,
        metadata: { wise_account_id: wise_account_id, error_class: e.class.name, error_message: e.message }
      )
      skipped_count += 1
    end

    return_to = safe_return_to_path

    if created_count > 0
      @wise_item.sync_later unless @wise_item.syncing?
      redirect_to return_to || accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count > 0 && created_count == 0
      redirect_to return_to || accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_wise_item_path(@wise_item, return_to: return_to), alert: t(".creation_failed", error: "Unknown error")
    end
  end

  private

    def set_wise_item
      @wise_item = Current.family.wise_items.find(params[:id])
    end

    def find_writable_account!(account_id)
      account = Current.user.accessible_accounts.find(account_id)
      raise ActiveRecord::RecordNotFound unless account.permission_for(Current.user).in?([ :owner, :full_control ])
      account
    end

    def wise_item_params
      params.require(:wise_item).permit(:name, :sync_start_date, :api_token)
    end

    def update_params
      permitted = wise_item_params
      permitted = permitted.except(:api_token) if permitted[:api_token].blank?
      permitted
    end

    def infer_accountable_type(account_type)
      case account_type&.downcase
      when "depository"   then "Depository"
      when "credit_card"  then "CreditCard"
      when "investment"   then "Investment"
      when "loan"         then "Loan"
      when "other_asset"  then "OtherAsset"
      else "Depository"
      end
    end

    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s

      begin
        uri = URI.parse(return_to)
        return nil if uri.scheme.present?
        return nil if uri.host.present?
        return nil unless return_to.start_with?("/")
        return_to
      rescue URI::InvalidURIError
        nil
      end
    end
end
