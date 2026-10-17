class TruelayerItemsController < ApplicationController
  include SafeProviderRedirect

  # Consent URLs are followed only on these hosts (or their subdomains).
  TRUSTED_TRUELAYER_HOSTS = %w[truelayer.com truelayer-sandbox.com].freeze
  SUPPORTED_ACCOUNT_TYPES = %w[Depository CreditCard Loan].freeze
  OAUTH_STATE_SESSION_KEY = :truelayer_oauth_states
  MAX_PENDING_OAUTH_STATES = 5

  before_action :require_admin!, only: %i[create update destroy sync connect reauthorize callback setup_accounts complete_account_setup select_existing_account link_existing_account]
  before_action :set_truelayer_item, only: %i[update destroy sync reauthorize setup_accounts complete_account_setup]

  # Saves the TrueLayer app credentials. The first connection holds them until
  # a bank is connected; later connections copy them.
  def create
    item = Current.family.truelayer_items.build(truelayer_item_params)
    item.name = item.default_name

    if item.save
      render_provider_panel("truelayer", notice: t(".success"))
    else
      render_provider_panel("truelayer", alert: item.errors.full_messages.to_sentence)
    end
  end

  # Updates the credentials on every connection, so they stay in step.
  def update
    attributes = truelayer_item_params.to_h.compact_blank
    TruelayerItem.transaction do
      Current.family.truelayer_items.find_each { |item| item.update!(attributes) }
    end
    render_provider_panel("truelayer", notice: t(".success"))
  rescue ActiveRecord::RecordInvalid => e
    render_provider_panel("truelayer", alert: e.record.errors.full_messages.to_sentence)
  end

  def destroy
    @truelayer_item.unlink_all!
    @truelayer_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    return redirect_to(settings_providers_path, alert: t(".not_connected"), status: :see_other) unless @truelayer_item.connected?

    @truelayer_item.sync_later unless @truelayer_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Starts TrueLayer's consent dialog for a new bank.
  def connect
    item = Current.family.truelayer_item_for_new_connection
    return redirect_to(settings_providers_path, alert: t(".credentials_required"), status: :see_other) unless item

    safe_redirect_to_truelayer(item.truelayer_provider.authorization_url(redirect_uri: callback_url, state: issue_oauth_state_for(item)))
  end

  # Renews consent for an existing bank. TrueLayer's re-auth link keeps the
  # same account ids; when it is refused (the refresh token has lapsed) a full
  # consent is used instead, and accounts are matched up again by id.
  def reauthorize
    provider = @truelayer_item.truelayer_provider
    state = issue_oauth_state_for(@truelayer_item)
    url = begin
      @truelayer_item.refresh_token.present? ? provider.reauthorization_url(refresh_token: @truelayer_item.refresh_token, redirect_uri: callback_url, state: state) : nil
    rescue Provider::Truelayer::TruelayerError => e
      Rails.logger.info "TrueLayer reauthuri refused for item #{@truelayer_item.id}, using full consent: #{e.message}"
      nil
    end

    safe_redirect_to_truelayer(url || provider.authorization_url(redirect_uri: callback_url, state: state))
  end

  def callback
    if params[:error].present?
      return redirect_to(settings_providers_path, alert: t(".authorization_error", error: params[:error_description].presence || params[:error]), status: :see_other)
    end

    item = consume_oauth_state(params[:state])
    if params[:code].blank? || item.nil?
      return redirect_to(settings_providers_path, alert: t(".invalid_callback"), status: :see_other)
    end

    item.complete_authorization!(code: params[:code], redirect_uri: callback_url)
    # Sync straight away: the bank releases full history only for a few
    # minutes after consent.
    item.sync_later
    redirect_to accounts_path, notice: t(".success"), status: :see_other
  rescue Provider::Truelayer::TruelayerError => e
    Rails.logger.error "TrueLayer authorization failed: #{e.message}"
    redirect_to settings_providers_path, alert: t(".authorization_failed", message: e.message), status: :see_other
  end

  def setup_accounts
    @truelayer_accounts = @truelayer_item.truelayer_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).order(:name)
    @account_type_options = [ [ t(".account_types.skip"), "skip" ] ] + SUPPORTED_ACCOUNT_TYPES.map { |type| [ t(".account_types.#{type.underscore}"), type ] }
    @subtype_options = {
      "Depository" => { label: t(".subtype_labels.depository"), options: Depository::SUBTYPES.keys.map { |key| [ Depository.long_subtype_label_for(key), key ] } },
      "CreditCard" => { label: t(".subtype_labels.credit_card"), options: [], message: t(".subtype_messages.credit_card") },
      "Loan" => { label: t(".subtype_labels.loan"), options: Loan::SUBTYPES.keys.map { |key| [ Loan.long_subtype_label_for(key), key ] } }
    }
  end

  def complete_account_setup
    account_types = params[:account_types]&.to_unsafe_h || {}
    account_subtypes = params[:account_subtypes]&.to_unsafe_h || {}
    created = 0

    ActiveRecord::Base.transaction do
      # Transactions before this date stay out of the linked accounts; blank
      # keeps everything the bank provided.
      @truelayer_item.update!(sync_start_date: params[:sync_start_date].presence) if params.key?(:sync_start_date)

      account_types.each do |truelayer_account_id, selected_type|
        next unless SUPPORTED_ACCOUNT_TYPES.include?(selected_type)

        truelayer_account = @truelayer_item.truelayer_accounts.find_by(id: truelayer_account_id)
        next if truelayer_account.nil? || truelayer_account.account_provider.present?

        subtype = account_subtypes[truelayer_account_id].presence
        subtype ||= "credit_card" if selected_type == "CreditCard"
        subtype = nil unless selected_type.constantize::SUBTYPES.keys.map(&:to_s).include?(subtype)

        account = Account.create_and_sync(
          {
            family: Current.family,
            name: truelayer_account.name,
            balance: truelayer_account.current_balance || 0,
            currency: truelayer_account.currency,
            accountable_type: selected_type,
            accountable_attributes: subtype ? { subtype: subtype } : {}
          },
          skip_initial_sync: true
        )
        AccountProvider.create!(account: account, provider: truelayer_account)
        created += 1
      end
    end

    if created.positive?
      @truelayer_item.sync_later
      redirect_to accounts_path, notice: t(".success", count: created), status: :see_other
    else
      redirect_to accounts_path, notice: t(".all_skipped"), status: :see_other
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    redirect_to accounts_path, alert: t(".creation_failed", error: e.message), status: :see_other
  end

  # Links an unlinked TrueLayer account to an existing manual account.
  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @truelayer_accounts = TruelayerAccount.where(truelayer_item: Current.family.truelayer_items.active)
      .left_joins(:account_provider).where(account_providers: { id: nil })
      .includes(:truelayer_item).order(:name)
    render :select_existing_account, layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    truelayer_account = TruelayerAccount.where(truelayer_item: Current.family.truelayer_items.active).find(params[:truelayer_account_id])

    if account.account_providers.any?
      return redirect_to(account_path(account), alert: t(".only_manual"), status: :see_other)
    end
    if truelayer_account.account_provider.present?
      return redirect_to(account_path(account), alert: t(".already_linked"), status: :see_other)
    end

    AccountProvider.create!(account: account, provider: truelayer_account)
    truelayer_account.truelayer_item.sync_later
    redirect_to accounts_path, notice: t(".success", account_name: account.name), status: :see_other
  end

  private

    def set_truelayer_item
      @truelayer_item = Current.family.truelayer_items.find(params[:id])
    end

    def truelayer_item_params
      params.require(:truelayer_item).permit(:client_id, :client_secret)
    end

    def callback_url
      helpers.truelayer_callback_url
    end

    # Pending states map state => item id, so parallel flows (two tabs) each
    # keep theirs. The list is bounded so abandoned flows can't grow the
    # session cookie.
    def issue_oauth_state_for(item)
      state = SecureRandom.urlsafe_base64(32)
      pending = pending_oauth_states.merge(state => item.id)
      session[OAUTH_STATE_SESSION_KEY] = pending.to_a.last(MAX_PENDING_OAUTH_STATES).to_h
      state
    end

    # Consumes only the matching state, so a made-up or stale state cannot
    # cancel a real flow in progress.
    def consume_oauth_state(state)
      pending = pending_oauth_states
      matched = pending.keys.find { |candidate| ActiveSupport::SecurityUtils.secure_compare(candidate, state.to_s) }
      return unless matched

      item_id = pending.delete(matched)
      session[OAUTH_STATE_SESSION_KEY] = pending
      Current.family.truelayer_items.find_by(id: item_id)
    end

    def pending_oauth_states
      pending = session[OAUTH_STATE_SESSION_KEY]
      pending.is_a?(Hash) ? pending.to_h : {}
    end

    def safe_redirect_to_truelayer(url)
      safe_redirect_to_provider(
        url,
        trusted_hosts: TRUSTED_TRUELAYER_HOSTS,
        fallback_path: settings_providers_path,
        fallback_alert: t("truelayer_items.redirect_blocked"),
        status: :see_other
      )
    end
end
