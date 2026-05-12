class IbkrItemsController < ApplicationController
  before_action :set_ibkr_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :create, :select_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def create
    @ibkr_item = Current.family.ibkr_items.build(ibkr_item_params)
    @ibkr_item.name ||= t("ibkr_items.defaults.name")

    if @ibkr_item.save
      @ibkr_item.sync_later

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        render turbo_stream: [
          turbo_stream.replace(
            "ibkr-providers-panel",
            partial: "settings/providers/ibkr_panel"
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @ibkr_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "ibkr-providers-panel",
          partial: "settings/providers/ibkr_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end
  end

  def update
    attrs = ibkr_item_params.to_h
    attrs["query_id"] = @ibkr_item.query_id if attrs["query_id"].blank?
    attrs["token"] = @ibkr_item.token if attrs["token"].blank?

    if @ibkr_item.update(attrs.merge(status: :good))
      @ibkr_item.sync_later unless @ibkr_item.syncing?

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        render turbo_stream: [
          turbo_stream.replace(
            "ibkr-providers-panel",
            partial: "settings/providers/ibkr_panel"
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @ibkr_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "ibkr-providers-panel",
          partial: "settings/providers/ibkr_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end
  end

  def destroy
    begin
      @ibkr_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("IBKR unlink during destroy failed: #{e.class} - #{e.message}")
    end

    @ibkr_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @ibkr_item.sync_later unless @ibkr_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    ibkr_item = current_ibkr_item
    unless ibkr_item
      redirect_to settings_providers_path, alert: t(".not_configured")
      return
    end

    redirect_to setup_accounts_ibkr_item_path(ibkr_item)
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @available_ibkr_accounts = Current.family.ibkr_items
      .includes(ibkr_accounts: { account_provider: :account })
      .flat_map(&:ibkr_accounts)
      .select { |ibkr_account| ibkr_account.account_provider.nil? }
      .sort_by { |ibkr_account| ibkr_account.updated_at || ibkr_account.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find_by(id: params[:account_id])
    ibkr_account = Current.family.ibkr_items
      .joins(:ibkr_accounts)
      .where(ibkr_accounts: { id: params[:ibkr_account_id] })
      .first
      &.ibkr_accounts
      &.find_by(id: params[:ibkr_account_id])

    if account.blank? || ibkr_account.blank?
      redirect_to settings_providers_path, alert: t(".not_found")
      return
    end

    if account.accountable_type != "Investment" || account.account_providers.any? || account.plaid_account_id.present? || account.simplefin_account_id.present?
      redirect_to account_path(account), alert: t(".only_manual_investment")
      return
    end

    provider = nil

    ibkr_account.with_lock do
      if ibkr_account.current_account.present?
        redirect_to account_path(account), alert: t(".already_linked")
        return
      end

      provider = ibkr_account.ensure_account_provider!(account)
    end

    raise "Failed to create AccountProvider link" unless provider

    begin
      IbkrAccount::Processor.new(ibkr_account.reload).process
    rescue => e
      Rails.logger.error("Failed to process linked IBKR account #{ibkr_account.id}: #{e.class} - #{e.message}")
    end

    ibkr_account.ibkr_item.sync_later unless ibkr_account.ibkr_item.syncing?
    redirect_to account_path(account), notice: t(".success"), status: :see_other
  rescue => e
    Rails.logger.error("Failed to link existing IBKR account: #{e.class} - #{e.message}")
    redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
  end

  def setup_accounts
    @ibkr_accounts = @ibkr_item.ibkr_accounts.includes(account_provider: :account)
    @linked_accounts = @ibkr_accounts.select { |ibkr_account| ibkr_account.current_account.present? }
    @unlinked_accounts = @ibkr_accounts.reject { |ibkr_account| ibkr_account.current_account.present? }

    no_accounts = @linked_accounts.blank? && @unlinked_accounts.blank?
    latest_sync = @ibkr_item.syncs.ordered.first
    should_sync = latest_sync.nil? || !latest_sync.completed?

    if no_accounts && !@ibkr_item.syncing? && should_sync
      @ibkr_item.sync_later
    end

    @linkable_accounts = Current.family.accounts
      .visible
      .where(accountable_type: "Investment")
      .left_joins(:account_providers)
      .where(account_providers: { id: nil })
      .order(:name)

    @syncing = @ibkr_item.syncing?
    @waiting_for_sync = no_accounts && @syncing
    @no_accounts_found = no_accounts && !@syncing && @ibkr_item.last_synced_at.present?
  end

  def complete_account_setup
    selected_accounts = Array(params[:account_ids]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |ibkr_account_id|
      ibkr_account = @ibkr_item.ibkr_accounts.find_by(id: ibkr_account_id)
      next unless ibkr_account

      ibkr_account.with_lock do
        next if ibkr_account.current_account.present?

        account = Account.create_from_ibkr_account(ibkr_account)
        ibkr_account.ensure_account_provider!(account)
        created_accounts << account
      end

      begin
        IbkrAccount::Processor.new(ibkr_account.reload).process
      rescue => e
        Rails.logger.error("Failed to process IBKR account #{ibkr_account.id} after setup: #{e.class} - #{e.message}")
      end
    end

    @ibkr_item.update!(pending_account_setup: @ibkr_item.unlinked_accounts_count.positive?)
    @ibkr_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to accounts_path, notice: t(".success", count: created_accounts.count), status: :see_other
    elsif selected_accounts.empty?
      redirect_to setup_accounts_ibkr_item_path(@ibkr_item), alert: t(".none_selected"), status: :see_other
    else
      redirect_to setup_accounts_ibkr_item_path(@ibkr_item), alert: t(".none_created"), status: :see_other
    end
  end

  private

    def set_ibkr_item
      @ibkr_item = Current.family.ibkr_items.find(params[:id])
    end

    def current_ibkr_item
      active_items = Current.family.ibkr_items.active

      active_items.syncable.ordered.first || active_items.ordered.first
    end

    def ibkr_item_params
      params.require(:ibkr_item).permit(:name, :query_id, :token)
    end
end
