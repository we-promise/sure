# frozen_string_literal: true

class RedbarkItemsController < ApplicationController
  ALLOWED_ACCOUNTABLE_TYPES = %w[Depository CreditCard Investment Loan OtherAsset OtherLiability Crypto Property Vehicle].freeze

  before_action :set_redbark_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @redbark_items = Current.family.redbark_items.ordered
  end

  def show
  end

  def new
    @redbark_item = Current.family.redbark_items.build
  end

  def edit
  end

  def create
    @redbark_item = Current.family.redbark_items.build(redbark_item_params)
    @redbark_item.name ||= "Redbark Connection"

    if @redbark_item.save
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured Redbark.")
        @redbark_items = Current.family.redbark_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "redbark-providers-panel",
            partial: "settings/providers/redbark_panel",
            locals: { redbark_items: @redbark_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @redbark_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "redbark-providers-panel",
          partial: "settings/providers/redbark_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @redbark_item.update(redbark_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated Redbark configuration.")
        @redbark_items = Current.family.redbark_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "redbark-providers-panel",
            partial: "settings/providers/redbark_panel",
            locals: { redbark_items: @redbark_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @redbark_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "redbark-providers-panel",
          partial: "settings/providers/redbark_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @redbark_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled Redbark connection for deletion.")
  end

  def sync
    unless @redbark_item.syncing?
      @redbark_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Collection actions for account linking flow

  def preload_accounts
    # Trigger a sync to fetch accounts from the provider
    redbark_item = Current.family.redbark_items.first
    unless redbark_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    redbark_item.sync_later unless redbark_item.syncing?
    redirect_to select_accounts_redbark_items_path(accountable_type: params[:accountable_type], return_to: params[:return_to])
  end

  def select_accounts
    redbark_item = Current.family.redbark_items.first
    unless redbark_item&.credentials_configured?
      if turbo_frame_request?
        render partial: "redbark_items/setup_required", layout: false
      else
        redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      end
      return
    end

    # The account-linking UI lives in the setup_accounts view
    redirect_to setup_accounts_redbark_item_path(redbark_item, return_to: safe_return_to_path)
  end

  def link_accounts
    redbark_item = Current.family.redbark_items.first
    unless redbark_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    selected_ids = params[:selected_account_ids] || []
    if selected_ids.empty?
      redirect_to select_accounts_redbark_items_path, alert: t(".no_accounts_selected")
      return
    end

    accountable_type = params[:accountable_type] || "Depository"
    created_count = 0
    already_linked_count = 0
    invalid_count = 0

    redbark_item.redbark_accounts.where(id: selected_ids).find_each do |redbark_account|
      # Skip if already linked
      if redbark_account.account_provider.present?
        already_linked_count += 1
        next
      end

      # Skip if invalid name
      if redbark_account.name.blank?
        invalid_count += 1
        next
      end

      # Create Sure account and link
      link_redbark_account(redbark_account, accountable_type)
      created_count += 1
    rescue => e
      Rails.logger.error "RedbarkItemsController#link_accounts - Failed to link account: #{e.message}"
    end

    if created_count > 0
      redbark_item.sync_later unless redbark_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    else
      redirect_to select_accounts_redbark_items_path, alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @redbark_item = Current.family.redbark_items.first

    unless @redbark_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @redbark_accounts = @redbark_item.redbark_accounts
                                                      .left_joins(:account_provider)
                                                      .where(account_providers: { id: nil })
                                                      .order(:name)
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    redbark_item = Current.family.redbark_items.first

    unless redbark_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    redbark_account = redbark_item.redbark_accounts.find(params[:redbark_account_id])

    if redbark_account.account_provider.present?
      redirect_to account_path(account), alert: t(".provider_account_already_linked")
      return
    end

    redbark_account.ensure_account_provider!(account)
    redbark_item.sync_later unless redbark_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @unlinked_accounts = @redbark_item.unlinked_redbark_accounts.order(:name)

    if @unlinked_accounts.empty?
      redirect_to accounts_path, notice: t(".all_accounts_linked")
    end
  end

  def complete_account_setup
    account_configs = params[:accounts] || {}

    if account_configs.empty?
      redirect_to setup_accounts_redbark_item_path(@redbark_item), alert: t(".no_accounts")
      return
    end

    created_count = 0
    skipped_count = 0

    account_configs.each do |redbark_account_id, config|
      next if config[:account_type] == "skip"

      redbark_account = @redbark_item.redbark_accounts.find_by(id: redbark_account_id)
      next unless redbark_account
      next if redbark_account.account_provider.present?

      accountable_type = infer_accountable_type(config[:account_type], config[:subtype])
      account = create_account_from_redbark(redbark_account, accountable_type, config)

      if account&.persisted?
        redbark_account.ensure_account_provider!(account)
        redbark_account.update!(sync_start_date: config[:sync_start_date]) if config[:sync_start_date].present?
        created_count += 1
      else
        skipped_count += 1
      end
    rescue => e
      Rails.logger.error "RedbarkItemsController#complete_account_setup - Error: #{e.message}"
      skipped_count += 1
    end

    if created_count > 0
      @redbark_item.sync_later unless @redbark_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count > 0 && created_count == 0
      redirect_to accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_redbark_item_path(@redbark_item), alert: t(".creation_failed", error: "Unknown error")
    end
  end

  private

    def set_redbark_item
      @redbark_item = Current.family.redbark_items.find(params[:id])
    end

    # Only allow internal relative paths in return_to
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

    def redbark_item_params
      params.require(:redbark_item).permit(
        :name,
        :sync_start_date,
        :api_key
      )
    end

    def link_redbark_account(redbark_account, accountable_type)
      accountable_class = validated_accountable_class(accountable_type)

      account = Current.family.accounts.create!(
        name: redbark_account.name,
        balance: redbark_account.current_balance || 0,
        currency: redbark_account.currency || "AUD",
        accountable: accountable_class.new
      )

      redbark_account.ensure_account_provider!(account)
      account
    end

    def create_account_from_redbark(redbark_account, accountable_type, config)
      accountable_class = validated_accountable_class(accountable_type)
      accountable_attrs = {}

      # Set subtype if the accountable supports it
      if config[:subtype].present? && accountable_class.respond_to?(:subtypes)
        accountable_attrs[:subtype] = config[:subtype]
      end

      Current.family.accounts.create!(
        name: redbark_account.name,
        balance: config[:balance].present? ? config[:balance].to_d : (redbark_account.current_balance || 0),
        currency: redbark_account.currency || "AUD",
        accountable: accountable_class.new(accountable_attrs)
      )
    end

    def infer_accountable_type(account_type, subtype = nil)
      case account_type&.downcase
      when "depository"
        "Depository"
      when "credit_card"
        "CreditCard"
      when "investment"
        "Investment"
      when "loan"
        "Loan"
      when "other_asset"
        "OtherAsset"
      when "other_liability"
        "OtherLiability"
      when "crypto"
        "Crypto"
      when "property"
        "Property"
      when "vehicle"
        "Vehicle"
      else
        "Depository"
      end
    end

    def validated_accountable_class(accountable_type)
      unless ALLOWED_ACCOUNTABLE_TYPES.include?(accountable_type)
        raise ArgumentError, "Invalid accountable type: #{accountable_type}"
      end

      accountable_type.constantize
    end
end
