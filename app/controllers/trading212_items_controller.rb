class Trading212ItemsController < ApplicationController
  before_action :set_trading212_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :create, :select_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def create
    @trading212_item = Current.family.trading212_items.build(trading212_item_params)
    @trading212_item.name ||= t("trading212_items.defaults.name")
    @trading212_item.currency ||= Current.family.currency

    if @trading212_item.save
      @trading212_item.sync_later

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        render turbo_stream: [
          turbo_stream.replace(
            "trading212-providers-panel",
            partial: "settings/providers/trading212_panel"
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @trading212_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "trading212-providers-panel",
          partial: "settings/providers/trading212_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end
  end

  def update
    attrs = trading212_item_params.to_h
    attrs["api_key"] = @trading212_item.api_key if attrs["api_key"].blank?
    attrs["api_secret"] = @trading212_item.api_secret if attrs["api_secret"].blank?

    if @trading212_item.update(attrs.merge(status: :good))
      @trading212_item.sync_later unless @trading212_item.syncing?

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        render turbo_stream: [
          turbo_stream.replace(
            "trading212-providers-panel",
            partial: "settings/providers/trading212_panel"
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @trading212_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "trading212-providers-panel",
          partial: "settings/providers/trading212_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end
  end

  def destroy
    begin
      @trading212_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("Trading 212 unlink during destroy failed: #{e.class} - #{e.message}")
    end

    @trading212_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @trading212_item.sync_later unless @trading212_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    item = current_trading212_item
    unless item
      redirect_to settings_providers_path, alert: t(".not_configured")
      return
    end

    redirect_to setup_accounts_trading212_item_path(item)
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @available_trading212_accounts = Current.family.trading212_items
      .includes(trading212_accounts: { account_provider: :account })
      .flat_map(&:trading212_accounts)
      .select { |t212_account| t212_account.account_provider.nil? }
      .sort_by { |t212_account| t212_account.updated_at || t212_account.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find_by(id: params[:account_id])
    t212_account = Current.family.trading212_items
      .joins(:trading212_accounts)
      .where(trading212_accounts: { id: params[:trading212_account_id] })
      .first
      &.trading212_accounts
      &.find_by(id: params[:trading212_account_id])

    if account.blank? || t212_account.blank?
      redirect_to settings_providers_path, alert: t(".not_found")
      return
    end

    if account.accountable_type != "Investment" || account.account_providers.any? || account.plaid_account_id.present? || account.simplefin_account_id.present?
      redirect_to account_path(account), alert: t(".only_manual_investment")
      return
    end

    provider = nil

    t212_account.with_lock do
      if t212_account.current_account.present?
        redirect_to account_path(account), alert: t(".already_linked")
        return
      end

      provider = t212_account.ensure_account_provider!(account)
    end

    raise "Failed to create AccountProvider link" unless provider

    begin
      Trading212Account::Processor.new(t212_account.reload).process
    rescue => e
      Rails.logger.error("Failed to process linked Trading 212 account #{t212_account.id}: #{e.class} - #{e.message}")
    end

    t212_account.trading212_item.sync_later unless t212_account.trading212_item.syncing?
    redirect_to account_path(account), notice: t(".success"), status: :see_other
  rescue => e
    Rails.logger.error("Failed to link existing Trading 212 account: #{e.class} - #{e.message}")
    redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
  end

  def setup_accounts
    @trading212_accounts = @trading212_item.trading212_accounts.includes(account_provider: :account)
    @linked_accounts = @trading212_accounts.select { |a| a.current_account.present? }
    @unlinked_accounts = @trading212_accounts.reject { |a| a.current_account.present? }

    no_accounts = @linked_accounts.blank? && @unlinked_accounts.blank?
    latest_sync = @trading212_item.syncs.ordered.first
    should_sync = latest_sync.nil? || !latest_sync.completed?

    if no_accounts && !@trading212_item.syncing? && should_sync
      @trading212_item.sync_later
    end

    @linkable_accounts = Current.family.accounts
      .visible
      .where(accountable_type: "Investment")
      .left_joins(:account_providers)
      .where(account_providers: { id: nil })
      .order(:name)

    @syncing = @trading212_item.syncing?
    @waiting_for_sync = no_accounts && @syncing
    @no_accounts_found = no_accounts && !@syncing && @trading212_item.last_synced_at.present?
  end

  def complete_account_setup
    selected_accounts = Array(params[:account_ids]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |t212_account_id|
      t212_account = @trading212_item.trading212_accounts.find_by(id: t212_account_id)
      next unless t212_account

      t212_account.with_lock do
        next if t212_account.current_account.present?

        account = Account.create_from_trading212_account(t212_account)
        t212_account.ensure_account_provider!(account)
        created_accounts << account
      end

      begin
        Trading212Account::Processor.new(t212_account.reload).process
      rescue => e
        Rails.logger.error("Failed to process Trading 212 account #{t212_account.id} after setup: #{e.class} - #{e.message}")
      end
    end

    @trading212_item.update!(pending_account_setup: @trading212_item.unlinked_accounts_count.positive?)
    @trading212_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to accounts_path, notice: t(".success", count: created_accounts.count), status: :see_other
    elsif selected_accounts.empty?
      redirect_to setup_accounts_trading212_item_path(@trading212_item), alert: t(".none_selected"), status: :see_other
    else
      redirect_to setup_accounts_trading212_item_path(@trading212_item), alert: t(".none_created"), status: :see_other
    end
  end

  private

    def set_trading212_item
      @trading212_item = Current.family.trading212_items.find(params[:id])
    end

    def current_trading212_item
      active_items = Current.family.trading212_items.active
      active_items.syncable.ordered.first || active_items.ordered.first
    end

    def trading212_item_params
      params.require(:trading212_item).permit(:api_key, :api_secret, :environment, :currency)
    end
end
