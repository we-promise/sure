# frozen_string_literal: true

class RedbarkItemsController < ApplicationController
  ALLOWED_ACCOUNTABLE_TYPES = %w[Depository CreditCard Investment Loan OtherAsset OtherLiability Crypto Property Vehicle].freeze

  before_action :set_redbark_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :create, :select_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def create
    @redbark_item = Current.family.redbark_items.build(redbark_item_params)
    @redbark_item.name ||= t("redbark_items.default_name")

    if @redbark_item.save
      # Trigger the initial sync so accounts appear without a manual refresh
      @redbark_item.sync_later

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
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
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end
  end

  def update
    update_params = redbark_item_params
    # A fresh key means the connection can be retried - clear requires_update
    update_params = update_params.merge(status: :good) if update_params[:api_key].present?

    if @redbark_item.update(update_params)
      # Rotated credentials should be exercised right away
      @redbark_item.sync_later if update_params[:api_key].present? && !@redbark_item.syncing?

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
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
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end
  end

  def destroy
    # Detach provider links before scheduling deletion; abort if anything
    # failed to unlink so we never orphan holdings or provider links
    unlink_results = @redbark_item.unlink_all!(dry_run: false)
    failed = unlink_results.select { |r| r[:error].present? }

    if failed.any?
      redirect_to settings_providers_path, alert: t(".unlink_failed", count: failed.count), status: :see_other
      return
    end

    @redbark_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
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

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @redbark_item = Current.family.redbark_items.first

    unless @redbark_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @redbark_accounts = @redbark_item.redbark_accounts
                                                      .without_linked
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

    if account.account_providers.exists?
      redirect_to account_path(account), alert: t(".account_already_linked")
      return
    end

    redbark_account.ensure_account_provider!(account)
    redbark_account.update!(ignored: false)
    redbark_item.sync_later unless redbark_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    # A fresh connection has no imported accounts yet - fetch them inline so
    # the setup dialog is usable straight after the API key is saved
    @api_error = fetch_redbark_accounts_from_api

    @unlinked_accounts = @redbark_item.unlinked_redbark_accounts.order(:name)

    if @unlinked_accounts.empty? && @api_error.nil?
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
    failed_count = 0

    account_configs.each do |redbark_account_id, config|
      redbark_account = @redbark_item.redbark_accounts.find_by(id: redbark_account_id)
      next unless redbark_account
      next if redbark_account.account_provider.present?

      # Remember the user's choice to skip so the account stops resurfacing
      # as "needs setup" on every sync
      if config[:account_type] == "skip" || config[:account_type].blank?
        redbark_account.update!(ignored: true)
        skipped_count += 1
        next
      end

      accountable_type = infer_accountable_type(config[:account_type], config[:subtype])

      # Atomic: roll back the manual account if linking the provider fails
      ActiveRecord::Base.transaction do
        account = create_account_from_redbark(redbark_account, accountable_type, config)
        redbark_account.ensure_account_provider!(account)
        redbark_account.update!(ignored: false)
        redbark_account.update!(sync_start_date: config[:sync_start_date]) if config[:sync_start_date].present?
      end
      created_count += 1
    rescue => e
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Redbark account setup failed",
        source: self.class.name,
        provider_key: "redbark",
        family: Current.family,
        metadata: { redbark_account_id: redbark_account_id, error_class: e.class.name, error: e.message }
      )
      failed_count += 1
    end

    @redbark_item.sync_later if created_count > 0 && !@redbark_item.syncing?

    if failed_count > 0
      redirect_to setup_accounts_redbark_item_path(@redbark_item), alert: t(".setup_failed", count: failed_count)
    elsif created_count > 0
      redirect_to accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count > 0
      redirect_to accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_redbark_item_path(@redbark_item), alert: t(".creation_failed_generic")
    end
  end

  private

    def set_redbark_item
      @redbark_item = Current.family.redbark_items.find(params[:id])
    end

    # Imports accounts synchronously when the item has none yet.
    # Returns nil on success, or an error message string on failure.
    def fetch_redbark_accounts_from_api
      return nil if @redbark_item.redbark_accounts.any?
      return t("redbark_items.setup_accounts.no_api_key") unless @redbark_item.credentials_configured?

      @redbark_item.import_latest_redbark_data
      nil
    rescue Provider::Redbark::Error => e
      t("redbark_items.setup_accounts.api_error", message: e.message)
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Inline Redbark account fetch failed",
        source: self.class.name,
        provider_key: "redbark",
        family: Current.family,
        metadata: { redbark_item_id: @redbark_item.id, error_class: e.class.name, error: e.message }
      )
      t("redbark_items.setup_accounts.api_error", message: e.message)
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
      redbark_account.update!(ignored: false)
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
