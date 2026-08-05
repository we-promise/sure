# frozen_string_literal: true

class PluggyItemsController < ApplicationController
  ALLOWED_ACCOUNTABLE_TYPES = %w[Depository CreditCard Investment Loan OtherAsset OtherLiability Crypto Property Vehicle].freeze

  before_action :set_pluggy_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  # All provider mutations (create/update/sync/link/setup) are admin-only —
  # mirrors RedbarkItemsController. Read/list views (index/show/new/edit) stay
  # open so a non-admin family member can still view the providers panel. The
  # existing controller tests sign in `users(:family_admin)`, which satisfies
  # `require_admin!` (Current.user.admin?).
  before_action :require_admin!, only: [ :create, :update, :destroy, :sync, :setup_accounts, :complete_account_setup, :preload_accounts, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account ]

  def index
    @pluggy_items = Current.family.pluggy_items.ordered
  end

  def show
  end

  def new
    # Keep connect flow anchored in Providers UI (drawer/modal).
    redirect_to connect_form_settings_providers_path(provider_key: "pluggy"), status: :see_other
  end

  def edit
  end

  def create
    @pluggy_item = Current.family.pluggy_items.build(pluggy_item_params)
    @pluggy_item.name ||= "Pluggy Connection"

    # Widget path POSTs only `pluggy_item_id` (no client_id/secret); the
    # returned itemId is only usable paired with the family's developer
    # credentials, which minted the connect token (see
    # #issue_pluggy_connect_token). Inherit them from the family's existing
    # credentialed PluggyItem so the importer can authenticate against Pluggy.
    if @pluggy_item.pluggy_item_id.present? && !@pluggy_item.credentials_configured?
      source = preferred_credentialed_pluggy_item
      if source&.credentials_configured?
        @pluggy_item.client_id = source.client_id
        @pluggy_item.client_secret = source.client_secret
      end
    end

    if @pluggy_item.save
      if should_auto_connect?(@pluggy_item)
        redirect_to connect_form_settings_providers_path(provider_key: "pluggy"),
                    notice: t(".connect_next", default: "Credentials saved. Continue with Pluggy Connect."),
                    status: :see_other
        return
      end

      # Enqueue the initial sync on a successful create for both the
      # credential flow and the PluggyConnect widget `item_id` flow. Unlike
      # Plaid there is no public_token exchange — the widget's returned
      # `itemId` is stored verbatim on `pluggy_item_id` and is usable directly
      # with the developer credentials (see PluggyItem::Provider#item_id), so
      # we kick off the sync immediately. The upstream item id is no longer
      # eagerly hydrated on this request (moved into PluggyItem::Syncer#perform_sync),
      # so enqueue the sync on credentials alone — the Syncer discovers the id
      # when the job runs. The widget-path POST still supplies `pluggy_item_id`
      # via params, which the Syncer's hydrate step treats as a no-op.
      @pluggy_item.sync_later if @pluggy_item.credentials_configured? && !@pluggy_item.syncing?

      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured Pluggy.")
        @pluggy_items = Current.family.pluggy_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "pluggy-providers-panel",
            partial: "settings/providers/pluggy_panel",
            locals: { pluggy_items: @pluggy_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @pluggy_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "pluggy-providers-panel",
          partial: "settings/providers/pluggy_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    attrs = pluggy_item_params

    # `client_secret` is rendered as a `password_field` (blank value, no DOM
    # leak of the decrypted secret — see _pluggy_panel). Leaving the field
    # blank on an edit means "keep the existing secret", not "clear it" — drop
    # the blank param so the update doesn't wipe the stored credential and
    # silently break `credentials_configured?`.
    attrs.delete(:client_secret) if attrs[:client_secret].blank?

    # Credential-first path: if we still don't have an item id, try to discover
    # an existing Pluggy item for this family before persisting the update.
    if @pluggy_item.pluggy_item_id.blank?
      hydrated_item = @pluggy_item.dup
      hydrated_item.assign_attributes(attrs)
      PluggyItem.hydrate_item_id!(hydrated_item)
      attrs[:pluggy_item_id] = hydrated_item.pluggy_item_id if hydrated_item.pluggy_item_id.present?
    end

    if @pluggy_item.update(attrs)
      # `update` is only reached from the "Update Configuration" credential form on
      # the providers panel. Don't force the Pluggy Connect drawer open on every
      # credential change — the user expects a plain save (see _pluggy_panel). The
      # "Open Pluggy Connect" launcher and the "Connect" link already carry the
      # connect intent explicitly. `create` keeps the auto-connect bridge for
      # first-time credential setup (new record, no item id).
      @pluggy_item.sync_later if @pluggy_item.pluggy_item_id.present? && !@pluggy_item.syncing?

      if turbo_frame_request?
        # Bake the success toast INTO the panel (#pluggy-panel-notice) instead of
        # appending to #notification-tray: the Pluggy Connect drawer (native <dialog>
        # via showModal()) paints in the browser top layer and occludes the z-50
        # #notification-tray, so a tray-appended toast is invisible while the drawer
        # is open. Rendering the notice inside the panel makes it visible in either
        # render context (drawer or main page). Drop flash_notification_stream_items
        # for this path so the tray isn't touched. The non-turbo `else` keeps its
        # flash:notice redirect — no drawer open there, so the tray is fine.
        @pluggy_items = Current.family.pluggy_items.ordered
        # Mint a connect token so the re-rendered panel keeps its "Open Pluggy Connect"
        # launcher — the partial gates the widget box on @connect_token. Without this
        # the turbo-stream update would hide the button the user saved credentials to use.
        @connect_token, @connect_item = issue_pluggy_connect_token(Current.family)
        notice_message = t(".success", default: "Successfully updated Pluggy configuration.")
        render turbo_stream: [
          # Drawer: `update` re-renders the <turbo-frame id="pluggy-connect-form"
          # target="_top"> wrapper in place — the frame keeps its dialog lifecycle and
          # Stimulus wiring. The partial bakes in the notice via `notice_message:`.
          turbo_stream.update(
            "pluggy-connect-form",
            partial: "settings/providers/pluggy_panel",
            locals: { pluggy_items: @pluggy_items, notice_message: notice_message }
          ),
          # Main page: existing `replace` behavior, now also carrying the inline
          # notice so the toast is visible there too instead of via the occluded tray.
          turbo_stream.replace(
            "pluggy-providers-panel",
            partial: "settings/providers/pluggy_panel",
            locals: { pluggy_items: @pluggy_items, notice_message: notice_message }
          )
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @pluggy_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "pluggy-providers-panel",
          partial: "settings/providers/pluggy_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @pluggy_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled Pluggy connection for deletion.")
  end

  def sync
    unless @pluggy_item.pluggy_item_id.present?
      respond_to do |format|
        format.html { redirect_back_or_to accounts_path, alert: t(".missing_item_id") }
        format.json { render json: { error: t(".missing_item_id") }, status: :unprocessable_entity }
      end
      return
    end

    unless @pluggy_item.syncing?
      @pluggy_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Collection actions for account linking flow

  def preload_accounts
    # Trigger a sync to fetch accounts from the provider
    pluggy_item = preferred_pluggy_item
    unless pluggy_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    PluggyItem.hydrate_item_id!(pluggy_item)

    unless pluggy_item.pluggy_item_id.present?
      redirect_to settings_providers_path,
                  alert: t(".missing_item_id_for_sync", default: "No Pluggy item found for these credentials yet.")
      return
    end

    pluggy_item.sync_later unless pluggy_item.syncing?
    redirect_to select_accounts_pluggy_items_path(accountable_type: params[:accountable_type], return_to: params[:return_to])
  end

  def select_accounts
    @accountable_type = params[:accountable_type]
    @return_to = params[:return_to]

    pluggy_item = preferred_pluggy_item
    @credentials_configured = pluggy_item&.credentials_configured?

    unless @credentials_configured
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @pluggy_accounts = pluggy_item.pluggy_accounts
                                                .left_joins(:account_provider)
                                                .where(account_providers: { id: nil })
                                                .order(:name)
  end

  def link_accounts
    pluggy_item = preferred_pluggy_item
    unless pluggy_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    selected_ids = params[:selected_account_ids] || []
    if selected_ids.empty?
      redirect_to select_accounts_pluggy_items_path, alert: t(".no_accounts_selected")
      return
    end

    accountable_type = params[:accountable_type] || "Depository"
    created_count = 0
    already_linked_count = 0
    invalid_count = 0

    pluggy_item.pluggy_accounts.where(id: selected_ids).find_each do |pluggy_account|
      # Skip if already linked
      if pluggy_account.account_provider.present?
        already_linked_count += 1
        next
      end

      # Skip if invalid name
      if pluggy_account.name.blank?
        invalid_count += 1
        next
      end

      # Create Sure account and link
      link_pluggy_account(pluggy_account, accountable_type)
      created_count += 1
    rescue => e
      Rails.logger.error "PluggyItemsController#link_accounts - Failed to link account: #{e.message}"
    end

    if created_count > 0
      pluggy_item.sync_later unless pluggy_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    else
      redirect_to select_accounts_pluggy_items_path, alert: t(".link_failed")
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @pluggy_item = preferred_pluggy_item

    unless @pluggy_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @pluggy_accounts = @pluggy_item.pluggy_accounts
                                                      .left_joins(:account_provider)
                                                      .where(account_providers: { id: nil })
                                                      .order(:name)
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    pluggy_item = preferred_pluggy_item

    unless pluggy_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_api_key")
      return
    end

    pluggy_account = pluggy_item.pluggy_accounts.find(params[:pluggy_account_id])

    if pluggy_account.account_provider.present?
      redirect_to account_path(account), alert: t(".provider_account_already_linked")
      return
    end

    pluggy_account.ensure_account_provider!(account)
    pluggy_item.sync_later unless pluggy_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  end

  def setup_accounts
    @unlinked_accounts = @pluggy_item.unlinked_pluggy_accounts.order(:name)

    if @unlinked_accounts.empty?
      redirect_to accounts_path, notice: t(".all_accounts_linked")
    end
  end

  def complete_account_setup
    account_configs = params[:accounts] || {}

    if account_configs.empty?
      redirect_to setup_accounts_pluggy_item_path(@pluggy_item), alert: t(".no_accounts")
      return
    end

    created_count = 0
    skipped_count = 0

    account_configs.each do |pluggy_account_id, config|
      next if config[:account_type] == "skip"

      pluggy_account = @pluggy_item.pluggy_accounts.find_by(id: pluggy_account_id)
      next unless pluggy_account
      next if pluggy_account.account_provider.present?

      accountable_type = infer_accountable_type(config[:account_type], config[:subtype])
      account = create_account_from_pluggy(pluggy_account, accountable_type, config)

      if account&.persisted?
        pluggy_account.ensure_account_provider!(account)
        pluggy_account.update!(sync_start_date: config[:sync_start_date]) if config[:sync_start_date].present?
        created_count += 1
      else
        skipped_count += 1
      end
    rescue => e
      Rails.logger.error "PluggyItemsController#complete_account_setup - Error: #{e.message}"
      skipped_count += 1
    end

    if created_count > 0
      @pluggy_item.sync_later unless @pluggy_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created_count)
    elsif skipped_count > 0 && created_count == 0
      redirect_to accounts_path, notice: t(".all_skipped")
    else
      redirect_to setup_accounts_pluggy_item_path(@pluggy_item), alert: t(".creation_failed", error: "Unknown error")
    end
  end

  private

    def set_pluggy_item
      @pluggy_item = Current.family.pluggy_items.find(params[:id])
    end

    def pluggy_item_params
      params.require(:pluggy_item).permit(
        :name,
        :sync_start_date,
        :client_id,
        :client_secret,
        :pluggy_item_id
      )
    end

    # Returns a [connectToken, pluggyItem] pair for the family's Connect
    # widget — the token, and the exact record it was minted for (exposed by
    # callers as @connect_item so the panel can wire is-update/item-id/
    # record-id from it). Prefers an already-connected item so the token binds
    # to its `pluggy_item_id` (UPDATE mode — re-auth/refresh); falls back to
    # the first credentialed item for a CREATE-mode token. A create-mode token
    # minted for a family that already has an item is what Pluggy rejects as
    # ITEM_USER_ALREADY_EXISTS, so the item_id binding is the fix. Network
    # failures are swallowed so dev/test renders without live creds.
    def issue_pluggy_connect_token(family)
      item = PluggyItem.preferred_for_connect(family)
      return [ nil, nil ] unless item&.credentials_configured?

      # Hydrate the upstream item id before minting so the connect token binds
      # to the existing Pluggy item (UPDATE mode) instead of creating a new one.
      # Without this, a row with a blank `pluggy_item_id` mints a CREATE-mode
      # token; combined with the hardcoded `avoidDuplicates: true` below, Pluggy
      # rejects it with ITEM_USER_ALREADY_EXISTS whenever an item already exists
      # for the family's `clientUserId`. Mirrors the connect_form path in
      # Settings::ProvidersController (which also hydrates via PluggyItem.hydrate_item_id!).
      # When creds are invalid the hydrate rescue returns the item unchanged and
      # connect_token raises into the outer rescue — same end state as before.
      item = PluggyItem.hydrate_item_id!(item)

      token = item.pluggy_provider.connect_token( # pipelock:ignore Credential in URL
        client_user_id: item.client_user_id,
        webhook_url: item.webhook_url,
        redirect_url: item.redirect_url,
        item_id: item.pluggy_item_id.presence
      )
      [ token, item ]
    rescue StandardError
      [ nil, nil ]
    end

    def preferred_pluggy_item
      Current.family.pluggy_items.where.not(pluggy_item_id: [ nil, "" ]).ordered.first ||
        preferred_credentialed_pluggy_item ||
        Current.family.pluggy_items.ordered.first
    end

    def preferred_credentialed_pluggy_item
      Current.family.pluggy_items.where.not(client_id: [ nil, "" ]).ordered.first
    end

    def should_auto_connect?(item)
      item.credentials_configured? && item.pluggy_item_id.blank?
    end

    def link_pluggy_account(pluggy_account, accountable_type)
      accountable_class = validated_accountable_class(accountable_type)

      account = Current.family.accounts.create!(
        name: pluggy_account.name,
        balance: pluggy_account.current_balance || 0,
        currency: pluggy_account.currency || "USD",
        accountable: accountable_class.new
      )

      pluggy_account.ensure_account_provider!(account)
      account
    end

    def create_account_from_pluggy(pluggy_account, accountable_type, config)
      accountable_class = validated_accountable_class(accountable_type)
      accountable_attrs = {}

      # Set subtype if the accountable supports it
      if config[:subtype].present? && accountable_class.respond_to?(:subtypes)
        accountable_attrs[:subtype] = config[:subtype]
      end

      Current.family.accounts.create!(
        name: pluggy_account.name,
        balance: config[:balance].present? ? config[:balance].to_d : (pluggy_account.current_balance || 0),
        currency: pluggy_account.currency || "USD",
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
