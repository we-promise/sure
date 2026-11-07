class StashawayItemsController < ApplicationController
  MEMBER_ACTIONS = %i[destroy sync login verify_code resend_code cancel_login forget_password setup_accounts complete_account_setup].freeze

  before_action :set_stashaway_item, only: MEMBER_ACTIONS
  before_action :require_admin!
  # Setup would create and link accounts that the pending deletion then
  # leaves behind as unlinked manual accounts.
  before_action :refuse_scheduled_for_deletion, only: %i[setup_accounts complete_account_setup]

  # Signs in a new connection. The item is saved only once StashAway
  # accepted the email and password.
  def create
    @stashaway_item = Current.family.stashaway_items.build(
      email: login_params[:email].to_s.strip,
      region: login_params[:region].presence || Provider::Stashaway::Region::DEFAULT_CODE,
      status: :requires_update
    )
    return render_panel(alert: @stashaway_item.errors.full_messages.to_sentence) unless @stashaway_item.valid?

    @stashaway_item.name = @stashaway_item.institution_display_name

    start_login
  end

  # Signs an existing connection in again, with the email and region it was
  # set up with.
  def login
    start_login
  end

  def verify_code
    @stashaway_item.complete_login!(code: params.dig(:stashaway_login, :code))
    @stashaway_item.sync_later unless @stashaway_item.syncing?
    render_panel(notice: t(".success"))
  rescue StashawayItem::Authentication::LoginExpired
    @stashaway_item.cancel_login!
    render_panel(alert: t("stashaway_items.login.code_expired"))
  rescue Provider::Stashaway::InvalidCode => e
    render_panel(alert: t(".invalid_code", detail: e.message))
  rescue Provider::Stashaway::Error => e
    render_login_error(e)
  end

  def resend_code
    @stashaway_item.resend_login_code!
    render_panel(notice: t(".success"))
  rescue StashawayItem::Authentication::LoginExpired
    @stashaway_item.cancel_login!
    render_panel(alert: t("stashaway_items.login.code_expired"))
  rescue Provider::Stashaway::Error => e
    render_login_error(e)
  end

  def cancel_login
    @stashaway_item.cancel_login!
    render_panel
  end

  def forget_password
    @stashaway_item.forget_password!
    render_panel(notice: t(".success"))
  end

  def destroy
    @stashaway_item.unlink_all!(dry_run: false)
    @stashaway_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @stashaway_item.sync_later if @stashaway_item.ready_for_sync? && !@stashaway_item.syncing?
    return render_panel(notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    item = Current.family.stashaway_items.active.syncable.ordered.first || Current.family.stashaway_items.active.ordered.first
    return frame_redirect_to(settings_providers_path, alert: t(".not_configured")) unless item

    redirect_to setup_accounts_stashaway_item_path(item)
  end

  def select_existing_account
    @account = Current.user.accessible_accounts.find(params[:account_id])
    # require_admin! checks the family role, not this account.
    return unless require_account_permission!(@account, :write, redirect_path: accounts_path)

    @available_stashaway_accounts = Current.family.stashaway_items.active
      .includes(stashaway_accounts: { account_provider: :account })
      .flat_map(&:stashaway_accounts)
      .select { |stashaway_account| stashaway_account.account_provider.nil? && stashaway_account.linkable_to?(@account) }
      .sort_by(&:name)

    render :select_existing_account, layout: false
  end

  def link_existing_account
    account = Current.user.accessible_accounts.find_by(id: params[:account_id])
    stashaway_account = StashawayAccount.joins(:stashaway_item)
      .merge(Current.family.stashaway_items.active)
      .find_by(id: params[:stashaway_account_id])
    return redirect_to(settings_providers_path, alert: t(".not_found")) if account.blank? || stashaway_account.blank?
    return unless require_account_permission!(account, :write, redirect_path: accounts_path)

    unless stashaway_account.linkable_to?(account) && manual_account?(account)
      return redirect_to(account_path(account), alert: t(".only_manual"))
    end

    # AccountProvider is unique per provider type, so a link from another
    # provider that commits after the check above would stand beside this
    # one. The Sure account's lock serialises the links, and the check is
    # repeated under it.
    outcome = account.with_lock do
      next :only_manual unless manual_account?(account)

      stashaway_account.with_lock do
        next :already_linked if stashaway_account.current_account.present?

        stashaway_account.link_to!(account)
        :linked
      end
    end
    return redirect_to(account_path(account), alert: t(".only_manual")) if outcome == :only_manual
    return redirect_to(account_path(account), alert: t(".already_linked")) if outcome == :already_linked

    process_after_linking(stashaway_account)
    redirect_to account_path(account), notice: t(".success"), status: :see_other
  rescue ActiveRecord::ActiveRecordError => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "Failed to link an existing account to StashAway: #{e.class} - #{e.message}",
      source: "stashaway",
      family: Current.family,
      provider_key: "stashaway"
    )
    redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
  end

  def setup_accounts
    @stashaway_accounts = @stashaway_item.stashaway_accounts.includes(account_provider: :account).order(:name)
    @linked_accounts, @unlinked_accounts = @stashaway_accounts.partition { |stashaway_account| stashaway_account.current_account.present? }

    no_accounts = @stashaway_accounts.empty?
    @stashaway_item.sync_later if no_accounts && @stashaway_item.ready_for_sync? && !@stashaway_item.syncing? && @stashaway_item.last_synced_at.nil?

    # Linking manages the account, so only the ones this user may write to.
    @linkable_accounts = Current.family.accounts
      .visible_manual
      .writable_by(Current.user)
      .where(accountable_type: %w[Investment Depository])
      .order(:name)

    @syncing = @stashaway_item.syncing?
    @waiting_for_sync = no_accounts && @syncing
    @no_accounts_found = no_accounts && !@syncing && @stashaway_item.last_synced_at.present?
    # A connection waiting for its code or a new sign-in has not synced, so
    # there is nothing to set up until it does.
    @never_synced = no_accounts && !@syncing && @stashaway_item.last_synced_at.nil?
  end

  def complete_account_setup
    selected_ids = Array(params[:account_ids]).compact_blank
    created = selected_ids.filter_map do |stashaway_account_id|
      stashaway_account = @stashaway_item.stashaway_accounts.find_by(id: stashaway_account_id)
      next unless stashaway_account

      account = stashaway_account.with_lock do
        next if stashaway_account.current_account.present?

        Account.create_from_stashaway_account(stashaway_account).tap { |new_account| stashaway_account.link_to!(new_account) }
      end
      next unless account

      process_after_linking(stashaway_account, schedule_sync: false)
      account
    end

    @stashaway_item.update!(pending_account_setup: @stashaway_item.unlinked_accounts_count.positive?)

    if created.any?
      @stashaway_item.sync_later if @stashaway_item.ready_for_sync? && !@stashaway_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created.size), status: :see_other
    else
      redirect_to setup_accounts_stashaway_item_path(@stashaway_item), alert: t(selected_ids.empty? ? ".none_selected" : ".none_created"), status: :see_other
    end
  end

  private

    def set_stashaway_item
      @stashaway_item = Current.family.stashaway_items.find(params[:id])
    end

    def refuse_scheduled_for_deletion
      return unless @stashaway_item.scheduled_for_deletion?

      frame_redirect_to(accounts_path, alert: t("stashaway_items.scheduled_for_deletion"))
    end

    def login_params
      params.fetch(:stashaway_login, {}).permit(:email, :password, :region, :remember_password)
    end

    # The password reaches StashAway and, unless the user asked for it to be
    # kept, nothing else: it is then neither assigned to the item nor kept
    # past this request. The item keeps it only once StashAway accepted it
    # and only when encryption is configured.
    def start_login
      password = login_params[:password].to_s
      return render_panel(alert: t("stashaway_items.login.password_required")) if password.blank?

      remember = ActiveModel::Type::Boolean.new.cast(login_params[:remember_password]) || false
      case @stashaway_item.start_login!(password: password, remember: remember)
      when :connected
        @stashaway_item.sync_later unless @stashaway_item.syncing?
        render_panel(notice: t("stashaway_items.login.connected"))
      else
        render_panel(notice: t("stashaway_items.login.code_sent"))
      end
    rescue Provider::Stashaway::InvalidCredentials => e
      render_panel(alert: t("stashaway_items.login.invalid_credentials", detail: e.message))
    rescue StashawayItem::Authentication::AlreadyConnected
      render_panel(alert: t("stashaway_items.login.already_connected"))
    rescue StashawayItem::Authentication::AccountMismatch
      render_panel(alert: t("stashaway_items.login.account_mismatch"))
    rescue Provider::Stashaway::Error => e
      render_login_error(e)
    end

    def render_login_error(error)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "StashAway sign-in failed: #{error.class} - #{error.message}",
        source: "stashaway",
        family: Current.family,
        provider_key: "stashaway"
      )
      render_panel(alert: error.message)
    end

    # A connection that failed to sign in for the first time is not saved;
    # the add form shows its email again.
    def render_panel(notice: nil, alert: nil)
      new_item = @stashaway_item if @stashaway_item&.new_record?
      render_provider_panel("stashaway", notice: notice, alert: alert, new_item: new_item)
    end

    def manual_account?(account)
      account.account_providers.none? && account.plaid_account_id.blank? && account.simplefin_account_id.blank?
    end

    def process_after_linking(stashaway_account, schedule_sync: true)
      StashawayAccount::Processor.new(stashaway_account.reload).process
      item = stashaway_account.stashaway_item
      item.sync_later if schedule_sync && item.ready_for_sync? && !item.syncing?
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Failed to process StashAway account #{stashaway_account.id} after linking: #{e.class} - #{e.message}",
        source: "stashaway",
        family: Current.family,
        account_provider: stashaway_account.account_provider,
        provider_key: "stashaway"
      )
    end
end
