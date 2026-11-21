class EtoroItemsController < ApplicationController
  before_action :set_etoro_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup, :update_display_mode ]
  before_action :require_admin!, only: [ :create, :select_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :setup_accounts, :complete_account_setup, :update_display_mode ]

  def create
    @etoro_item = Current.family.etoro_items.build(etoro_item_params)
    @etoro_item.name ||= t("settings.providers.etoro_panel.default_account_name")

    if @etoro_item.save
      @etoro_item.sync_later

      redirect_to accounts_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("etoro", alert: @etoro_item.errors.full_messages.join(", "))
    end
  end

  def update
    attrs = etoro_item_params.to_h
    attrs["api_key"] = @etoro_item.api_key if attrs["api_key"].blank?
    attrs["user_key"] = @etoro_item.user_key if attrs["user_key"].blank?

    if @etoro_item.update(attrs.merge(status: :good))
      @etoro_item.sync_later unless @etoro_item.syncing?

      render_provider_panel("etoro", notice: t(".success"), fallback_path: accounts_path)
    else
      render_provider_panel("etoro", alert: @etoro_item.errors.full_messages.join(", "))
    end
  end

  # A sync under way keeps writing to the accounts it loaded, which unlinking
  # would leave manual, so deletion waits for it to end.
  def destroy
    if @etoro_item.syncing?
      redirect_to settings_providers_path, alert: t(".syncing"), status: :see_other
      return
    end

    @etoro_item.unlink_all!(dry_run: false)
    @etoro_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @etoro_item.sync_later unless @etoro_item.syncing?
    return render_provider_panel("etoro", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # A change schedules a sync that rebuilds the linked account, and empties
  # or rebuilds the copy accounts when it leaves or enters copies, so it
  # takes write access to each of them: require_admin! checks the family
  # role, not the accounts. A sync under way may have processed the account
  # already, so the mode can't change until it ends, nor while the account
  # is disabled or being deleted, as the sync leaves it out.
  def update_display_mode
    etoro_account = @etoro_item.etoro_accounts.main_accounts.find(params[:etoro_account_id])
    mode = params[:display_mode].to_s
    return unless etoro_account.display_mode_accounts(mode).all? { |account| require_account_permission!(account, :write, redirect_path: accounts_path) }

    if @etoro_item.syncing?
      redirect_back_or_to accounts_path, alert: t(".syncing"), status: :see_other
    elsif !etoro_account.display_mode_changeable?
      redirect_back_or_to accounts_path, alert: t(".inactive"), status: :see_other
    elsif !EtoroAccount.display_modes.key?(mode)
      redirect_back_or_to accounts_path, alert: t(".invalid"), status: :see_other
    elsif etoro_account.display_mode == mode
      redirect_back_or_to accounts_path, status: :see_other
    else
      etoro_account.update!(display_mode: mode)
      @etoro_item.sync_later
      redirect_back_or_to accounts_path, notice: t(".success"), status: :see_other
    end
  end

  def select_accounts
    item = current_etoro_item
    unless item
      frame_redirect_to settings_providers_path, alert: t(".not_configured")
      return
    end

    redirect_to setup_accounts_etoro_item_path(item)
  end

  def select_existing_account
    @account = Current.user.accessible_accounts.find(params[:account_id])
    # require_admin! checks the family role, not this account: an admin who
    # neither owns it nor holds full_control must not link it.
    return unless require_account_permission!(@account, :write, redirect_path: accounts_path)

    @available_etoro_accounts = Current.family.etoro_items
      .includes(etoro_accounts: { account_provider: :account })
      .flat_map(&:etoro_accounts)
      .select { |etoro_account| etoro_account.account_provider.nil? }
      .sort_by { |etoro_account| etoro_account.updated_at || etoro_account.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    account = Current.user.accessible_accounts.find_by(id: params[:account_id])
    etoro_account = Current.family.etoro_items
      .joins(:etoro_accounts)
      .where(etoro_accounts: { id: params[:etoro_account_id] })
      .first
      &.etoro_accounts
      &.find_by(id: params[:etoro_account_id])

    # An account being deleted is gone once DestroyJob runs, link and all.
    if account.blank? || account.pending_deletion? || etoro_account.blank?
      redirect_to settings_providers_path, alert: t(".not_found")
      return
    end

    # Same guard as select_existing_account, ahead of the link it would create.
    return unless require_account_permission!(account, :write, redirect_path: accounts_path)
    return unless main_account_writable?(etoro_account, redirect_path: account_path(account))

    unless linkable?(account)
      redirect_to account_path(account), alert: t(".only_manual_investment")
      return
    end

    # Linking leaves the processing to the sync it asks for, as setup does,
    # so it waits for a sync under way too (see complete_account_setup).
    if etoro_account.etoro_item.syncing?
      redirect_to account_path(account), alert: t(".syncing")
      return
    end

    provider = nil

    # The account is locked too, and checked again under the lock, so a link
    # to another provider committed meanwhile is seen.
    etoro_account.with_lock do
      if etoro_account.current_account.present?
        redirect_to account_path(account), alert: t(".already_linked")
        return
      end

      account.lock!
      unless linkable?(account)
        redirect_to account_path(account), alert: t(".only_manual_investment")
        return
      end

      provider = etoro_account.ensure_account_provider!(account)
    end

    raise "Failed to create AccountProvider link" unless provider

    etoro_account.etoro_item.sync_later
    redirect_to account_path(account), notice: t(".success"), status: :see_other
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "Failed to link existing eToro account: #{e.class} - #{e.message}",
      source: "etoro",
      family: Current.family,
      provider_key: "etoro"
    )
    redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
  end

  def setup_accounts
    @etoro_accounts = @etoro_item.etoro_accounts.includes(account_provider: :account)
    @linked_accounts = @etoro_accounts.select { |a| a.current_account.present? }
    @unlinked_accounts = @etoro_accounts.reject { |a| a.current_account.present? }
    # Only an account shown as holdings keeps eToro's trades. A copy account
    # is always shown as copies, so the main accounts decide.
    @imports_trades = @etoro_accounts.reject(&:copy?).all?(&:shown_as_holdings?)

    no_accounts = @linked_accounts.blank? && @unlinked_accounts.blank?
    latest_sync = @etoro_item.syncs.ordered.first
    should_sync = latest_sync.nil? || !latest_sync.completed?

    # The setup frame's own polls don't start a sync, so a failed first sync
    # is retried only when the user asks (a button or reopening the page).
    polled = turbo_frame_request_id == "etoro-setup-accounts"
    if no_accounts && !polled && !@etoro_item.syncing? && should_sync
      @etoro_item.sync_later
    end

    # Linking manages the account, so only the ones this user may write to.
    @linkable_accounts = Current.family.accounts
      .visible_manual
      .writable_by(Current.user)
      .where(accountable_type: "Investment")
      .order(:name)

    @syncing = @etoro_item.syncing?
    # Setting up an account waits for a sync under way (see
    # complete_account_setup), and so does the page.
    @waiting_for_sync = @syncing
    # A sync that never completed counts as failed once it no longer counts
    # as under way, as when its job was lost, so the page offers a retry.
    @sync_failed = no_accounts && !@syncing && latest_sync.present? && !latest_sync.completed?
    @no_accounts_found = no_accounts && !@syncing && @etoro_item.last_synced_at.present?
  end

  # Setting up an account leaves the processing to the sync asked for
  # below: it resolves every instrument the account traded with the
  # securities providers, which takes longer than a request may. A sync
  # under way may have read the accounts before the setup, and asking for
  # a sync then returns that one rather than a new one, so setup waits
  # until it ends.
  def complete_account_setup
    if @etoro_item.syncing?
      redirect_to setup_accounts_etoro_item_path(@etoro_item), alert: t(".syncing"), status: :see_other
      return
    end

    selected_accounts = Array(params[:account_ids]).reject(&:blank?)
    selected = @etoro_item.etoro_accounts.where(id: selected_accounts).to_a
    return unless selected.all? { |etoro_account| main_account_writable?(etoro_account, redirect_path: setup_accounts_etoro_item_path(@etoro_item)) }

    created_accounts = []

    begin
      selected.each do |etoro_account|
        etoro_account.with_lock do
          next if etoro_account.current_account.present?

          account = Account.create_from_etoro_account(etoro_account)
          etoro_account.ensure_account_provider!(account)
          created_accounts << account
        end
      end
    ensure
      # The accounts set up before a failure stay linked and need their sync.
      @etoro_item.sync_later if created_accounts.any?
    end

    @etoro_item.update!(pending_account_setup: @etoro_item.unlinked_accounts_count.positive?)

    if created_accounts.any?
      redirect_to accounts_path, notice: t(".success", count: created_accounts.count), status: :see_other
    elsif selected_accounts.empty?
      redirect_to setup_accounts_etoro_item_path(@etoro_item), alert: t(".none_selected"), status: :see_other
    else
      redirect_to setup_accounts_etoro_item_path(@etoro_item), alert: t(".none_created"), status: :see_other
    end
  end

  private

    # A copy set up as an account takes its value out of the main account,
    # so both are processed, and neither counts the copy twice meanwhile.
    def set_etoro_item
      @etoro_item = Current.family.etoro_items.find(params[:id])
    end

    def current_etoro_item
      active_items = Current.family.etoro_items.active
      active_items.syncable.ordered.first || active_items.ordered.first
    end

    def linkable?(account)
      account.accountable_type == "Investment" && account.account_providers.none? && account.plaid_account_id.blank? && account.simplefin_account_id.blank?
    end

    # A copy set up as an account takes its value out of its main account,
    # and the sync rewrites that account, so it takes write access to it too.
    def main_account_writable?(etoro_account, redirect_path:)
      main = etoro_account.copy? ? etoro_account.main_account&.shown_account : nil
      main.nil? || require_account_permission!(main, :write, redirect_path: redirect_path)
    end

    def etoro_item_params
      params.require(:etoro_item).permit(:api_key, :user_key, :own_securities)
    end
end
