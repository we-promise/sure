# frozen_string_literal: true

class IndexaCapitalItemsController < ApplicationController
  ALLOWED_ACCOUNTABLE_TYPES = %w[Depository CreditCard Investment Loan OtherAsset OtherLiability Crypto Property Vehicle].freeze

  before_action :set_indexa_capital_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @indexa_capital_items = Current.family.indexa_capital_items.ordered
  end

  def show
  end

  def new
    @indexa_capital_item = Current.family.indexa_capital_items.build
  end

  def edit
  end

  def create
    @indexa_capital_item = Current.family.indexa_capital_items.build(indexa_capital_item_params)
    @indexa_capital_item.name ||= "IndexaCapital Connection"

    if @indexa_capital_item.save
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured IndexaCapital.")
        @indexa_capital_items = Current.family.indexa_capital_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "indexa_capital-providers-panel",
            partial: "settings/providers/indexa_capital_panel",
            locals: { indexa_capital_items: @indexa_capital_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @indexa_capital_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "indexa_capital-providers-panel",
          partial: "settings/providers/indexa_capital_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @indexa_capital_item.update(indexa_capital_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated IndexaCapital configuration.")
        @indexa_capital_items = Current.family.indexa_capital_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "indexa_capital-providers-panel",
            partial: "settings/providers/indexa_capital_panel",
            locals: { indexa_capital_items: @indexa_capital_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @indexa_capital_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "indexa_capital-providers-panel",
          partial: "settings/providers/indexa_capital_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @indexa_capital_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled IndexaCapital connection for deletion.")
  end

  def sync
    unless @indexa_capital_item.syncing?
      @indexa_capital_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Collection actions for account linking flow

  def preload_accounts
    # Trigger a sync to fetch accounts from the provider
    indexa_capital_item = Current.family.indexa_capital_items.first
    unless indexa_capital_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    indexa_capital_item.sync_later unless indexa_capital_item.syncing?
    redirect_to select_accounts_indexa_capital_items_path(accountable_type: params[:accountable_type], return_to: params[:return_to])
  end

  def select_accounts
    @accountable_type = params[:accountable_type]
    @return_to = params[:return_to]

    indexa_capital_item = Current.family.indexa_capital_items.first
    unless indexa_capital_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    # Always fetch fresh data (accounts + balances) when user visits this page
    fetch_accounts_synchronously(indexa_capital_item)

    @indexa_capital_accounts = indexa_capital_item.indexa_capital_accounts
                                                .left_joins(:account_provider)
                                                .where(account_providers: { id: nil })
                                                .order(:name)
  end

  def link_accounts
    indexa_capital_item = Current.family.indexa_capital_items.first
    unless indexa_capital_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    selected_ids = params[:selected_account_ids] || []
    if selected_ids.empty?
      redirect_to select_accounts_indexa_capital_items_path, alert: t(".no_accounts_selected")
      return
    end

    accountable_type = params[:accountable_type] || "Depository"
    created_count = 0
    already_linked_count = 0
    invalid_count = 0

    indexa_capital_item.indexa_capital_accounts.where(id: selected_ids).find_each do |indexa_capital_account|
      # Skip if already linked
      if indexa_capital_account.account_provider.present?
        already_linked_count += 1
        next
      end

      # Skip if invalid name
      if indexa_capital_account.name.blank?
        invalid_count += 1
        next
      end

      # Create Sure account and link
      link_indexa_capital_account(indexa_capital_account, accountable_type)
      created_count += 1
    rescue => e
      Rails.logger.error "IndexaCapitalItemsController#link_accounts - Failed to link account: #{e.message}"
    end

    if created_count > 0
      indexa_capital_item.sync_later unless indexa_capital_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    else
      redirect_to select_accounts_indexa_capital_items_path, alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @indexa_capital_item = Current.family.indexa_capital_items.first

    unless @indexa_capital_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @indexa_capital_accounts = @indexa_capital_item.indexa_capital_accounts
                                                      .left_joins(:account_provider)
                                                      .where(account_providers: { id: nil })
                                                      .order(:name)
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    indexa_capital_item = Current.family.indexa_capital_items.first

    unless indexa_capital_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    indexa_capital_account = indexa_capital_item.indexa_capital_accounts.find(params[:indexa_capital_account_id])

    if indexa_capital_account.account_provider.present?
      redirect_to account_path(account), alert: t(".provider_account_already_linked")
      return
    end

    indexa_capital_account.ensure_account_provider!(account)
    indexa_capital_item.sync_later unless indexa_capital_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @unlinked_accounts = @indexa_capital_item.unlinked_indexa_capital_accounts.order(:name)
  end

  def complete_account_setup
    account_configs = params[:accounts] || {}

    if account_configs.empty?
      redirect_to setup_accounts_indexa_capital_item_path(@indexa_capital_item), alert: t(".no_accounts")
      return
    end

    created_count = 0
    skipped_count = 0

    account_configs.each do |indexa_capital_account_id, config|
      next if config[:account_type] == "skip"

      indexa_capital_account = @indexa_capital_item.indexa_capital_accounts.find_by(id: indexa_capital_account_id)
      next unless indexa_capital_account
      next if indexa_capital_account.account_provider.present?

      accountable_type = infer_accountable_type(config[:account_type], config[:subtype])
      account = create_account_from_indexa_capital(indexa_capital_account, accountable_type, config)

      if account&.persisted?
        indexa_capital_account.ensure_account_provider!(account)
        indexa_capital_account.update!(sync_start_date: config[:sync_start_date]) if config[:sync_start_date].present?
        created_count += 1
      else
        skipped_count += 1
      end
    rescue => e
      Rails.logger.error "IndexaCapitalItemsController#complete_account_setup - Error: #{e.message}"
      skipped_count += 1
    end

    if created_count > 0
      @indexa_capital_item.sync_later unless @indexa_capital_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count > 0 && created_count == 0
      redirect_to accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_indexa_capital_item_path(@indexa_capital_item), alert: t(".creation_failed", error: "Unknown error")
    end
  end

  private

    def set_indexa_capital_item
      @indexa_capital_item = Current.family.indexa_capital_items.find(params[:id])
    end

    def indexa_capital_item_params
      params.require(:indexa_capital_item).permit(
        :name,
        :sync_start_date,
        :api_token,
        :username,
        :document,
        :password
      )
    end

    def link_indexa_capital_account(indexa_capital_account, accountable_type)
      accountable_class = validated_accountable_class(accountable_type)

      account = Current.family.accounts.create!(
        name: indexa_capital_account.name,
        balance: indexa_capital_account.current_balance || 0,
        currency: indexa_capital_account.currency || "EUR",
        accountable: accountable_class.new
      )

      indexa_capital_account.ensure_account_provider!(account)
      account
    end

    def create_account_from_indexa_capital(indexa_capital_account, accountable_type, config)
      accountable_class = validated_accountable_class(accountable_type)
      accountable_attrs = {}

      # Set subtype if the accountable supports it
      if config[:subtype].present? && accountable_class.respond_to?(:subtypes)
        accountable_attrs[:subtype] = config[:subtype]
      end

      Current.family.accounts.create!(
        name: indexa_capital_account.name,
        balance: config[:balance].present? ? config[:balance].to_d : (indexa_capital_account.current_balance || 0),
        currency: indexa_capital_account.currency || "EUR",
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

    def fetch_accounts_synchronously(indexa_capital_item)
      provider = indexa_capital_item.indexa_capital_provider
      return unless provider

      accounts_data = provider.list_accounts

      accounts_data.each do |account_data|
        account_number = account_data[:account_number].to_s
        next if account_number.blank?

        # Fetch current balance from performance endpoint
        balance = provider.get_account_balance(account_number: account_number)
        account_data[:current_balance] = balance
      rescue => e
        Rails.logger.warn "IndexaCapitalItemsController - Failed to fetch balance for #{account_number}: #{e.message}"
      end

      accounts_data.each do |account_data|
        account_number = account_data[:account_number].to_s
        next if account_number.blank?

        indexa_capital_account = indexa_capital_item.indexa_capital_accounts.find_or_initialize_by(
          indexa_capital_account_id: account_number
        )
        indexa_capital_account.upsert_from_indexa_capital!(account_data)
      end
    rescue Provider::IndexaCapital::AuthenticationError => e
      Rails.logger.error "IndexaCapitalItemsController - Auth failed during sync: #{e.message}"
      flash.now[:alert] = t("indexa_capital_items.select_accounts.api_error", message: e.message)
    rescue Provider::IndexaCapital::Error => e
      Rails.logger.error "IndexaCapitalItemsController - API error during sync: #{e.message}"
      flash.now[:alert] = t("indexa_capital_items.select_accounts.api_error", message: e.message)
    end
end
