# frozen_string_literal: true

class QuestradeItemsController < ApplicationController
  ALLOWED_ACCOUNTABLE_TYPES = %w[Depository CreditCard Investment Loan OtherAsset OtherLiability Crypto Property Vehicle].freeze

  before_action :set_questrade_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :create, :update, :destroy, :sync, :preload_accounts, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :setup_accounts, :complete_account_setup ]

  def index
    @questrade_items = Current.family.questrade_items.ordered
  end

  def show
  end

  def new
    @questrade_item = Current.family.questrade_items.build
  end

  def edit
  end

  def create
    @questrade_item = Current.family.questrade_items.build(questrade_item_params)
    @questrade_item.name ||= I18n.t("questrade_items.default_name")

    if @questrade_item.save
      # Kick off an initial sync so accounts are discovered and appear under the
      # Accounts tab for setup.
      @questrade_item.sync_later unless @questrade_item.syncing?

      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured Questrade.")
        @questrade_items = Current.family.questrade_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "questrade-providers-panel",
            partial: "settings/providers/questrade_panel",
            locals: { questrade_items: @questrade_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @questrade_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "questrade-providers-panel",
          partial: "settings/providers/questrade_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message
      end
    end
  end

  def update
    update_attrs = update_params
    # A fresh, non-blank token re-arms a connection that was marked requires_update.
    update_attrs = update_attrs.merge(status: :good) if update_attrs[:refresh_token].present?

    if @questrade_item.update(update_attrs)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated Questrade configuration.")
        @questrade_items = Current.family.questrade_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "questrade-providers-panel",
            partial: "settings/providers/questrade_panel",
            locals: { questrade_items: @questrade_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @questrade_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "questrade-providers-panel",
          partial: "settings/providers/questrade_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message
      end
    end
  end

  def destroy
    @questrade_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Disconnected Questrade."), status: :see_other
  end

  def sync
    unless @questrade_item.syncing?
      @questrade_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Collection actions for account linking flow

  def preload_accounts
    # Trigger a sync to fetch accounts from the provider
    questrade_item = Current.family.questrade_items.first
    unless questrade_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    questrade_item.sync_later unless questrade_item.syncing?
    redirect_to select_accounts_questrade_items_path(accountable_type: params[:accountable_type], return_to: params[:return_to])
  end

  def select_accounts
    questrade_item = Current.family.questrade_items.first
    unless questrade_item&.credentials_configured?
      if turbo_frame_request?
        render partial: "questrade_items/setup_required", layout: false
      else
        redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      end
      return
    end

    # The account-linking UI lives in the setup_accounts view (mirrors IBKR).
    redirect_to setup_accounts_questrade_item_path(questrade_item, return_to: safe_return_to_path)
  end

  def link_accounts
    questrade_item = Current.family.questrade_items.first
    unless questrade_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    selected_ids = params[:selected_account_ids] || []
    if selected_ids.empty?
      redirect_to select_accounts_questrade_items_path, alert: t(".no_accounts_selected")
      return
    end

    accountable_type = params[:accountable_type] || "Depository"
    created_count = 0
    already_linked_count = 0
    invalid_count = 0

    questrade_item.questrade_accounts.where(id: selected_ids).find_each do |questrade_account|
      # Skip if already linked
      if questrade_account.account_provider.present?
        already_linked_count += 1
        next
      end

      # Skip if invalid name
      if questrade_account.name.blank?
        invalid_count += 1
        next
      end

      # Create Sure account and link
      link_questrade_account(questrade_account, accountable_type)
      created_count += 1
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to link Questrade account",
        source: "QuestradeItemsController",
        provider_key: "questrade",
        family: Current.family,
        metadata: { questrade_account_id: questrade_account.id, error_class: e.class.name, error_message: e.message }
      )
    end

    if created_count > 0
      questrade_item.sync_later unless questrade_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    else
      redirect_to select_accounts_questrade_items_path, alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = find_writable_account!(params[:account_id])
    @questrade_item = Current.family.questrade_items.first

    unless @questrade_item&.credentials_configured?
      if turbo_frame_request?
        render partial: "questrade_items/setup_required", layout: false
      else
        redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      end
      return
    end

    @questrade_accounts = @questrade_item.questrade_accounts
                                                      .left_joins(:account_provider)
                                                      .where(account_providers: { id: nil })
                                                      .order(:name)
  end

  def link_existing_account
    account = find_writable_account!(params[:account_id])
    questrade_item = Current.family.questrade_items.first

    unless questrade_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    questrade_account = questrade_item.questrade_accounts.find(params[:questrade_account_id])

    if questrade_account.account_provider.present?
      redirect_to account_path(account), alert: t(".provider_account_already_linked")
      return
    end

    questrade_account.ensure_account_provider!(account)
    questrade_item.sync_later unless questrade_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @unlinked_accounts = @questrade_item.unlinked_questrade_accounts.order(:name)
    # When empty, the view renders an "all linked" message inside the modal
    # frame; redirecting to accounts_path here would dead-end the Turbo modal.
  end

  def complete_account_setup
    account_configs = params[:accounts] || {}

    if account_configs.empty?
      redirect_to setup_accounts_questrade_item_path(@questrade_item), alert: t(".no_accounts")
      return
    end

    created_count = 0
    skipped_count = 0

    account_configs.each do |questrade_account_id, config|
      next if config[:account_type] == "skip"

      questrade_account = @questrade_item.questrade_accounts.find_by(id: questrade_account_id)
      next unless questrade_account
      next if questrade_account.account_provider.present?

      accountable_type = infer_accountable_type(config[:account_type], config[:subtype])

      # Atomic: roll back the manual account if linking the provider fails.
      ActiveRecord::Base.transaction do
        account = create_account_from_questrade(questrade_account, accountable_type, config)
        questrade_account.ensure_account_provider!(account)
        questrade_account.update!(sync_start_date: config[:sync_start_date]) if config[:sync_start_date].present?
      end
      created_count += 1
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to create account during Questrade setup",
        source: "QuestradeItemsController",
        provider_key: "questrade",
        family: Current.family,
        metadata: { questrade_account_id: questrade_account_id, error_class: e.class.name, error_message: e.message }
      )
      skipped_count += 1
    end

    return_to = safe_return_to_path

    if created_count > 0
      @questrade_item.sync_later unless @questrade_item.syncing?
      redirect_to return_to || accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count > 0 && created_count == 0
      redirect_to return_to || accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_questrade_item_path(@questrade_item, return_to: return_to), alert: t(".creation_failed", error: "Unknown error")
    end
  end

  private

    def set_questrade_item
      @questrade_item = Current.family.questrade_items.find(params[:id])
    end

    # Mirror AccountsController's access gate: only accounts the user can reach
    # and write to may be inspected or linked to a provider.
    def find_writable_account!(account_id)
      account = Current.user.accessible_accounts.find(account_id)
      raise ActiveRecord::RecordNotFound unless account.permission_for(Current.user).in?([ :owner, :full_control ])
      account
    end

    def questrade_item_params
      params.require(:questrade_item).permit(
        :name,
        :sync_start_date,
        :refresh_token
      )
    end

    # Params for update: drop a blank refresh_token so an empty submission
    # never wipes the stored (still-valid) token.
    def update_params
      permitted = questrade_item_params
      permitted = permitted.except(:refresh_token) if permitted[:refresh_token].blank?
      permitted
    end

    def link_questrade_account(questrade_account, accountable_type)
      accountable_class = validated_accountable_class(accountable_type)

      # Atomic: a failure in ensure_account_provider! must roll back the account
      # so we never leave an orphan manual account behind.
      ActiveRecord::Base.transaction do
        account = Current.family.accounts.create!(
          name: questrade_account.name,
          balance: questrade_account.current_balance || 0,
          currency: questrade_account.currency || "USD",
          accountable: accountable_class.new
        )

        questrade_account.ensure_account_provider!(account)
        account
      end
    end

    def create_account_from_questrade(questrade_account, accountable_type, config)
      accountable_class = validated_accountable_class(accountable_type)
      accountable_attrs = {}

      # Set subtype if the accountable supports it
      if config[:subtype].present? && accountable_class.respond_to?(:subtypes)
        accountable_attrs[:subtype] = config[:subtype]
      end

      Current.family.accounts.create!(
        name: questrade_account.name,
        balance: config[:balance].present? ? config[:balance].to_d : (questrade_account.current_balance || 0),
        currency: questrade_account.currency || "USD",
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
