class SharesightItemsController < ApplicationController
  before_action :set_sharesight_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :create, :select_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def create
    @sharesight_item = Current.family.sharesight_items.build(sharesight_item_params)
    @sharesight_item.name ||= t("sharesight_items.defaults.name")

    if @sharesight_item.save
      @sharesight_item.sync_later

      redirect_to accounts_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("sharesight", alert: @sharesight_item.errors.full_messages.join(", "))
    end
  end

  def update
    attrs = sharesight_item_params.to_h
    attrs["client_id"] = @sharesight_item.client_id if attrs["client_id"].blank?
    attrs["client_secret"] = @sharesight_item.client_secret if attrs["client_secret"].blank?

    if @sharesight_item.update(attrs.merge(status: :good))
      @sharesight_item.sync_later unless @sharesight_item.syncing?

      render_provider_panel("sharesight", notice: t(".success"), fallback_path: accounts_path)
    else
      render_provider_panel("sharesight", alert: @sharesight_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @sharesight_item.unlink_all!(dry_run: false)
    @sharesight_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @sharesight_item.sync_later unless @sharesight_item.syncing?
    return render_provider_panel("sharesight", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    item = current_sharesight_item
    unless item
      frame_redirect_to settings_providers_path, alert: t(".not_configured")
      return
    end

    redirect_to setup_accounts_sharesight_item_path(item)
  end

  def select_existing_account
    @account = linkable_accounts.find(params[:account_id])
    @available_sharesight_accounts = Current.family.sharesight_items
      .includes(sharesight_accounts: { account_provider: :account })
      .flat_map(&:sharesight_accounts)
      .select { |sharesight_account| sharesight_account.account_provider.nil? }
      .sort_by { |sharesight_account| sharesight_account.updated_at || sharesight_account.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    account = linkable_accounts.find_by(id: params[:account_id])
    sharesight_account = SharesightAccount
      .joins(:sharesight_item)
      .where(sharesight_items: { family_id: Current.family.id })
      .find_by(id: params[:sharesight_account_id])

    if account.blank? || sharesight_account.blank?
      redirect_to settings_providers_path, alert: t(".not_found")
      return
    end

    if account.accountable_type != "Investment" || account.account_providers.any? || account.plaid_account_id.present? || account.simplefin_account_id.present?
      redirect_to account_path(account), alert: t(".only_manual_investment")
      return
    end

    provider = nil

    sharesight_account.with_lock do
      if sharesight_account.current_account.present?
        redirect_to account_path(account), alert: t(".already_linked")
        return
      end

      provider = sharesight_account.ensure_account_provider!(account)
    end

    raise "Failed to create AccountProvider link" unless provider

    process_after_linking(sharesight_account)

    sharesight_account.sharesight_item.sync_later unless sharesight_account.sharesight_item.syncing?
    redirect_to account_path(account), notice: t(".success"), status: :see_other
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "Failed to link existing Sharesight portfolio: #{e.class} - #{e.message}",
      source: "sharesight",
      family: Current.family,
      provider_key: "sharesight"
    )
    redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
  end

  def setup_accounts
    @sharesight_accounts = @sharesight_item.sharesight_accounts.includes(account_provider: :account).order(:name)
    @linked_accounts = @sharesight_accounts.select { |a| a.current_account.present? }
    @unlinked_accounts = @sharesight_accounts.reject { |a| a.current_account.present? }

    no_accounts = @linked_accounts.blank? && @unlinked_accounts.blank?
    latest_sync = @sharesight_item.syncs.ordered.first
    should_sync = latest_sync.nil? || !latest_sync.completed?

    if no_accounts && !@sharesight_item.syncing? && should_sync
      @sharesight_item.sync_later
    end

    @linkable_accounts = linkable_accounts
      .visible
      .where(accountable_type: "Investment")
      .where(plaid_account_id: nil, simplefin_account_id: nil)
      .left_joins(:account_providers)
      .where(account_providers: { id: nil })
      .order(:name)

    @syncing = @sharesight_item.syncing?
    @waiting_for_sync = no_accounts && @syncing
    @no_accounts_found = no_accounts && !@syncing && @sharesight_item.last_synced_at.present?
  end

  def complete_account_setup
    selected_accounts = Array(params[:account_ids]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |sharesight_account_id|
      sharesight_account = @sharesight_item.sharesight_accounts.find_by(id: sharesight_account_id)
      next unless sharesight_account

      linked = false
      sharesight_account.with_lock do
        next if sharesight_account.current_account.present?

        account = Account.create_from_sharesight_account(sharesight_account)
        # ensure_account_provider! returns nil if linking fails, so don't keep an account we couldn't link.
        raise ActiveRecord::Rollback unless sharesight_account.ensure_account_provider!(account)

        created_accounts << account
        linked = true
      end

      process_after_linking(sharesight_account) if linked
    end

    @sharesight_item.update!(pending_account_setup: @sharesight_item.unlinked_accounts_count.positive?)
    @sharesight_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to accounts_path, notice: t(".success", count: created_accounts.count), status: :see_other
    elsif selected_accounts.empty?
      redirect_to setup_accounts_sharesight_item_path(@sharesight_item), alert: t(".none_selected"), status: :see_other
    else
      redirect_to setup_accounts_sharesight_item_path(@sharesight_item), alert: t(".none_created"), status: :see_other
    end
  end

  private

    def set_sharesight_item
      @sharesight_item = Current.family.sharesight_items.find(params[:id])
    end

    def current_sharesight_item
      active_items = Current.family.sharesight_items.active
      active_items.syncable.ordered.first || active_items.ordered.first
    end

    def linkable_accounts
      Current.family.accounts.writable_by(Current.user)
    end

    # The value and holdings are already imported, so show them straight away.
    # The sync after this brings in the activity.
    def process_after_linking(sharesight_account)
      SharesightAccount::Processor.new(sharesight_account.reload).process
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Failed to process Sharesight portfolio #{sharesight_account.id} after linking: #{e.class} - #{e.message}",
        source: "sharesight",
        family: Current.family,
        provider_key: "sharesight"
      )
    end

    def sharesight_item_params
      params.require(:sharesight_item).permit(:client_id, :client_secret)
    end
end
