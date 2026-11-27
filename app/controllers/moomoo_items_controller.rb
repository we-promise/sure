class MoomooItemsController < ApplicationController
  include SafeProviderRedirect

  # The consent page is followed only on these hosts (or their subdomains).
  TRUSTED_MOOMOO_HOSTS = %w[moomoo.com].freeze
  OAUTH_STATE_SESSION_KEY = :moomoo_oauth_states
  MAX_PENDING_OAUTH_STATES = 3
  OAUTH_STATE_TTL = 15.minutes

  before_action :require_admin!
  before_action :set_moomoo_item, only: %i[destroy sync reauthorize]
  # A connection being removed takes no new accounts: DestroyJob would drop
  # their links and leave them empty.
  before_action :set_active_moomoo_item, only: %i[setup_accounts complete_account_setup]

  # Refused grants, by MoomooError#error_type; any other failure shows moomoo's message.
  AUTHORIZATION_FAILURE_KEYS = {
    scope_missing: ".scope_missing",
    write_scope_granted: ".write_scope_granted",
    already_connected: ".already_connected",
    client_replaced: ".invalid_callback"
  }.freeze
  CALLBACK_ERROR_MAX_LENGTH = 200

  # Posted with Turbo off, since the redirect leaves Sure.
  def connect
    item = Current.family.moomoo_item_for_new_connection(redirect_uri: callback_url)
    start_authorization(item, client_id: item.oauth_client_id, new_connection: true)
  rescue Provider::Moomoo::MoomooError => e
    log_auth_failure("client registration failed", e)
    redirect_to settings_providers_path, alert: t(".registration_failed", message: e.message), status: :see_other
  end

  # moomoo has no re-consent link, so this is a full consent for the same
  # connection: it renews one moomoo stopped accepting, and changes which
  # accounts a working one shares. Its accounts are matched up again by id.
  def reauthorize
    start_authorization(@moomoo_item, client_id: @moomoo_item.oauth_client_for_consent!(redirect_uri: callback_url))
  rescue Provider::Moomoo::MoomooError => e
    log_auth_failure("client registration failed", e)
    redirect_to settings_providers_path, alert: t(".registration_failed", message: e.message), status: :see_other
  end

  def callback
    pending = consume_oauth_state(params[:state])
    return redirect_to(settings_providers_path, alert: callback_error_message(pending), status: :see_other) if params[:error].present?

    item = pending && Current.family.moomoo_items.active.find_by(id: pending["item_id"])
    return redirect_to(settings_providers_path, alert: t(".invalid_callback"), status: :see_other) if item.nil? || params[:code].blank?

    item.complete_authorization!(
      code: params[:code], code_verifier: pending["code_verifier"], client_id: pending["client_id"], new_connection: pending["new_connection"] == true
    )
    item.sync_later
    redirect_to setup_accounts_moomoo_item_path(item), notice: t(".success"), status: :see_other
  rescue Provider::Moomoo::MoomooError => e
    log_auth_failure("authorization failed", e)
    redirect_to settings_providers_path, alert: t(AUTHORIZATION_FAILURE_KEYS.fetch(e.error_type, ".authorization_failed"), message: e.message), status: :see_other
  end

  def sync
    return redirect_to(settings_providers_path, alert: t(".reconnect_first"), status: :see_other) if @moomoo_item.needs_authorization?

    @moomoo_item.sync_later unless @moomoo_item.syncing?
    return render_provider_panel("moomoo", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # unlink_all! reports a failed unlink on its result rather than raising;
  # deleting the connection then would take that account's link with it.
  def destroy
    if @moomoo_item.unlink_all!(dry_run: false).any? { |result| result[:error].present? }
      return redirect_to(settings_providers_path, alert: t(".unlink_failed"), status: :see_other)
    end

    @moomoo_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def select_accounts
    item = Current.family.moomoo_items.syncable.ordered.first
    return frame_redirect_to(settings_providers_path, alert: t(".not_configured")) unless item

    redirect_to setup_accounts_moomoo_item_path(item)
  end

  def select_existing_account
    @account = Current.user.accessible_accounts.find(params[:account_id])
    # require_admin! checks the family role, not this account: an admin who
    # neither owns it nor holds full_control must not link it.
    return unless require_account_permission!(@account, :write, redirect_path: accounts_path)

    # A linked account takes its moomoo row's currency, which would leave the
    # account's own entries in the wrong currency, so only rows in its
    # currency are offered, and only those setup would offer (see
    # MoomooItem#setup_candidate_moomoo_accounts).
    candidate_ids = Current.family.moomoo_items.active.flat_map { |item| item.setup_candidate_moomoo_accounts.ids }
    @available_moomoo_accounts = MoomooAccount.where(id: candidate_ids)
      .set_up_as(@account.accountable_type)
      .where(currency: [ @account.currency, nil ])
      .order(updated_at: :desc)

    render :select_existing_account, layout: false
  end

  def link_existing_account
    account = Current.user.accessible_accounts.find_by(id: params[:account_id])
    moomoo_account = family_moomoo_accounts.find_by(id: params[:moomoo_account_id])
    return redirect_to(settings_providers_path, alert: t(".not_found"), status: :see_other) if account.blank? || moomoo_account.blank?
    # Same guard as select_existing_account, ahead of the link it would create.
    return unless require_account_permission!(account, :write, redirect_path: accounts_path)
    return redirect_to(account_path(account), alert: t(".unsupported_kind"), status: :see_other) unless moomoo_account.linkable?

    if account.accountable_type != moomoo_account.sure_accountable[:type] || account.account_providers.any? || account.plaid_account_id.present? || account.simplefin_account_id.present?
      return redirect_to(account_path(account), alert: t(".only_matching_manual_account"), status: :see_other)
    end
    if moomoo_account.currency.present? && moomoo_account.currency != account.currency
      return redirect_to(account_path(account), alert: t(".currency_mismatch", currency: moomoo_account.currency), status: :see_other)
    end

    # Linking leaves the processing to the sync it asks for. A sync under way
    # may have read the accounts before the link, and asking for a sync then
    # returns that one rather than a new one, so linking waits until it ends.
    return redirect_to(account_path(account), alert: t(".syncing"), status: :see_other) if moomoo_account.moomoo_item.syncing?

    link = moomoo_account.with_lock do
      next :already_linked if moomoo_account.current_account.present?
      # A row of a trading account the last import didn't fetch would never
      # update once linked, so it is refused as setup refuses it.
      next :not_shared unless moomoo_account.moomoo_item.setup_candidate_moomoo_accounts.exists?(moomoo_account.id)

      moomoo_account.ensure_account_provider!(account)
    end
    return redirect_to(account_path(account), alert: t(".already_linked"), status: :see_other) if link == :already_linked
    return redirect_to(account_path(account), alert: t(".not_shared"), status: :see_other) if link == :not_shared
    raise "Failed to create AccountProvider link" unless link

    moomoo_account.moomoo_item.sync_later
    redirect_to account_path(account), notice: t(".success"), status: :see_other
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "Failed to link existing moomoo account: #{e.class} - #{e.message}",
      source: "moomoo",
      family: Current.family,
      provider_key: "moomoo"
    )
    redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
  end

  def setup_accounts
    # Polled while the first sync runs: rows without their raw history.
    moomoo_accounts = @moomoo_item.moomoo_accounts.without_raw_payloads.includes(account_provider: :account).order(:created_at).to_a
    candidate_ids = @moomoo_item.setup_candidate_moomoo_accounts.pluck(:id).to_set
    @linked_accounts = moomoo_accounts.select { |moomoo_account| moomoo_account.current_account.present? }
    @unlinked_accounts = moomoo_accounts.select { |moomoo_account| candidate_ids.include?(moomoo_account.id) }
    @unsupported_accounts = moomoo_accounts.reject(&:linkable?)

    no_accounts = moomoo_accounts.empty?
    latest_sync = @moomoo_item.syncs.ordered.first
    should_sync = latest_sync.nil? || !latest_sync.completed?
    # The setup frame's own polls don't start a sync, so a failed first sync
    # is retried only when the user asks (a button or reopening the page).
    polled = turbo_frame_request_id == "moomoo-setup-accounts"
    @moomoo_item.sync_later if no_accounts && should_sync && !polled && !@moomoo_item.syncing? && !@moomoo_item.needs_authorization?

    # Each unlinked moomoo account with the manual accounts it can be linked
    # to: those of the type it is set up as and in its currency, which this
    # user may write to, since linking manages the account.
    manual_accounts = Current.family.accounts
      .visible_manual
      .writable_by(Current.user)
      .where(accountable_type: [ MoomooAccount::CASH_ACCOUNTABLE[:type], MoomooAccount::INVESTMENT_ACCOUNTABLE[:type] ])
      .order(:name)
      .group_by(&:accountable_type)
    @linkable_accounts = @unlinked_accounts
      .to_h do |moomoo_account|
        candidates = manual_accounts.fetch(moomoo_account.sure_accountable[:type], [])
        [ moomoo_account, candidates.select { |account| moomoo_account.currency.blank? || account.currency == moomoo_account.currency } ]
      end
      .reject { |_moomoo_account, accounts| accounts.empty? }

    @syncing = @moomoo_item.syncing?
    @waiting_for_sync = no_accounts && @syncing
    @sync_failed = no_accounts && !@syncing && (latest_sync&.failed? || latest_sync&.stale?)
    @no_accounts_found = no_accounts && !@syncing && @moomoo_item.last_synced_at.present?
  end

  # Setting up an account leaves the processing to the sync asked for
  # below: it resolves every security the account traded with the
  # securities providers, which takes longer than a request may. A sync
  # under way may have read the accounts before the setup, and asking for
  # a sync then returns that one rather than a new one, so setup waits
  # until it ends.
  def complete_account_setup
    if @moomoo_item.syncing?
      redirect_to setup_accounts_moomoo_item_path(@moomoo_item), alert: t(".syncing"), status: :see_other
      return
    end

    selected_ids = Array(params[:account_ids]).reject(&:blank?)
    created_accounts = []

    selected_ids.each do |moomoo_account_id|
      moomoo_account = @moomoo_item.setup_candidate_moomoo_accounts.find_by(id: moomoo_account_id)
      next unless moomoo_account

      account = moomoo_account.with_lock do
        next if moomoo_account.current_account.present?

        new_account = Account.create_from_moomoo_account(moomoo_account)
        raise ActiveRecord::Rollback unless moomoo_account.ensure_account_provider!(new_account)

        new_account
      end
      next unless account

      created_accounts << account
    end

    @moomoo_item.update!(pending_account_setup: @moomoo_item.unlinked_accounts_count.positive?)
    @moomoo_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to accounts_path, notice: t(".success", count: created_accounts.count), status: :see_other
    elsif selected_ids.empty?
      redirect_to setup_accounts_moomoo_item_path(@moomoo_item), alert: t(".none_selected"), status: :see_other
    else
      redirect_to setup_accounts_moomoo_item_path(@moomoo_item), alert: t(".none_created"), status: :see_other
    end
  end

  private

    def set_moomoo_item
      @moomoo_item = Current.family.moomoo_items.find(params[:id])
    end

    def set_active_moomoo_item
      @moomoo_item = Current.family.moomoo_items.active.find(params[:id])
    end

    def family_moomoo_accounts
      MoomooAccount.where(moomoo_item: Current.family.moomoo_items.active)
    end

    def callback_url
      helpers.moomoo_callback_url
    end

    # `client_id`: the client the consent runs with, the connection's own or
    # one pending on it (see MoomooItem#oauth_client_for_consent!).
    def start_authorization(item, client_id:, new_connection: false)
      pkce = Provider::Moomoo.generate_pkce
      state = issue_oauth_state_for(item, code_verifier: pkce[:verifier], client_id: client_id, new_connection: new_connection)
      url = item.authorization_url(state: state, code_challenge: pkce[:challenge], client_id: client_id)

      safe_redirect_to_provider(
        url,
        trusted_hosts: TRUSTED_MOOMOO_HOSTS,
        fallback_path: settings_providers_path,
        fallback_alert: t("moomoo_items.redirect_blocked"),
        status: :see_other
      )
    end

    # Pending flows map state => { item_id, code_verifier, client_id,
    # issued_at, new_connection }, so parallel flows (two tabs) each keep their
    # own. The PKCE verifier lives only here, in the encrypted session cookie.
    # Keys are strings because the cookie is JSON. The cookie holds 4 KB with
    # the rest of the session, an SSO login's id token among it, so the list is
    # short and expires, and new_connection is left out unless it is set.
    def issue_oauth_state_for(item, code_verifier:, client_id:, new_connection:)
      state = SecureRandom.urlsafe_base64(32)
      entry = { "item_id" => item.id, "code_verifier" => code_verifier, "client_id" => client_id,
                "issued_at" => Time.current.to_i, "new_connection" => (true if new_connection) }.compact
      session[OAUTH_STATE_SESSION_KEY] = pending_oauth_states.merge(state => entry).to_a.last(MAX_PENDING_OAUTH_STATES).to_h
      state
    end

    # Consumes only the matching state, so a made-up or stale state can't
    # cancel a real flow in progress.
    def consume_oauth_state(state)
      return nil if state.blank?

      pending = pending_oauth_states
      matched = pending.keys.find { |candidate| ActiveSupport::SecurityUtils.secure_compare(candidate, state.to_s) }
      return nil unless matched

      entry = pending.delete(matched)
      session[OAUTH_STATE_SESSION_KEY] = pending
      entry
    end

    def pending_oauth_states
      stored = session[OAUTH_STATE_SESSION_KEY]
      return {} unless stored.is_a?(Hash)

      stored.to_h.select { |_state, entry| entry.is_a?(Hash) && entry["issued_at"].to_i > OAUTH_STATE_TTL.ago.to_i }
    end

    # Anyone can link to the callback, so moomoo's own words are shown only
    # for a consent this session started, shortened to fit the cookie flash.
    def callback_error_message(pending)
      return t(".access_denied") if params[:error] == "access_denied"
      return t(".invalid_callback") unless pending

      t(".authorization_error", error: (params[:error_description].presence || params[:error]).to_s.squish.truncate(CALLBACK_ERROR_MAX_LENGTH))
    end

    def log_auth_failure(what, error)
      DebugLogEntry.capture(
        category: "provider_auth",
        level: "error",
        message: "moomoo #{what}: #{error.message}",
        source: "moomoo",
        provider_key: "moomoo",
        family: Current.family,
        metadata: { error_type: error.error_type, status: error.status, code: error.code }.compact
      )
    end
end
