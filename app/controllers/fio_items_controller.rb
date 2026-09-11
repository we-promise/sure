# frozen_string_literal: true

# Connections are created, updated and removed from the providers settings panel
# (app/views/settings/providers/_fio_panel.html.erb), and the account is linked through
# the dialogs in app/views/fio_items. There is deliberately no index/show/new/edit
# action: nothing links to them and they would have no template.
#
# A Fio token reaches exactly one account and Fio has no endpoint that lists accounts, so
# every screen here works on `fio_item.fio_account` — discovered by the first sync — and
# never offers a picker.
class FioItemsController < ApplicationController
  before_action :set_fio_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [
    :create, :select_accounts, :link_accounts,
    :select_existing_account, :link_existing_account, :update,
    :destroy, :sync, :setup_accounts, :complete_account_setup
  ]

  # Create a Fio connection and kick off its first sync.
  def create
    attributes = fio_item_params
    token = attributes[:token].to_s.strip

    if token.blank?
      render_provider_panel_error(t(".token_required"))
      return
    end

    Current.family.create_fio_item!(
      token: token,
      item_name: attributes[:name].presence,
      sync_start_date: attributes[:sync_start_date].presence
    )

    render_provider_panel(:notice, t(".success"))
  rescue ActiveRecord::RecordInvalid => e
    render_provider_panel_error(e.record.errors.full_messages.join(", "))
  end

  # Rotate the token and/or rename the connection and/or move its sync start date.
  def update
    attributes = update_params
    # A rotated token is the fix for the failed authorization that set requires_update.
    attributes[:status] = :good if attributes[:token].present? && @fio_item.requires_update?
    # A new token or a moved start date is a fresh attempt at the history, so the next
    # sync may reach for the whole range again. A rename is not: the form resubmits the
    # stored start date unchanged, and clearing the marker for that would spend the next
    # sync's single request on a period Fio has already refused.
    attributes[:history_unlock_required_at] = nil if history_attempt_renewed?(attributes)

    if @fio_item.update(attributes)
      # Nothing else checks a rotated token: status is set from the form, and only a
      # sync can find out whether Fio still accepts it. Without this the connection sits
      # marked healthy until the next scheduled run.
      @fio_item.sync_later unless @fio_item.syncing?
      render_provider_panel(:notice, t(".success"))
    else
      render_provider_panel_error(@fio_item.errors.full_messages.join(", "))
    end
  end

  # Unlink the account then schedule deletion of the connection.
  def destroy
    results = @fio_item.unlink_all!(dry_run: false)

    if results.any? { |result| result[:error].present? }
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Fio unlink during destroy failed",
        source: self.class.name,
        provider_key: "fio",
        family: @fio_item.family,
        metadata: { fio_item_id: @fio_item.id, failures: results.select { |r| r[:error].present? } }
      )
      redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
      return
    end

    @fio_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  rescue => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "warn",
      message: "Fio unlink during destroy failed",
      source: self.class.name,
      provider_key: "fio",
      family: @fio_item&.family,
      metadata: { fio_item_id: @fio_item&.id, error_class: e.class.name, error_message: e.message }
    )
    redirect_to settings_providers_path, alert: t(".unlink_failed"), status: :see_other
  end

  # Trigger a manual sync unless one is already running.
  #
  # Pressing Sync is also how a user says "I have just unlocked my full history in
  # internet banking": the unlock only lasts ten minutes, so the clamp is dropped here
  # and this sync reaches for the whole range again.
  def sync
    @fio_item.update!(history_unlock_required_at: nil) if @fio_item.history_unlock_required_at.present?
    @fio_item.sync_later unless @fio_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Render the confirmation screen for turning the connection's account into a new Sure
  # account. Reached from the new-account flow, so there is nothing to choose between.
  def select_accounts
    @accountable_type = requested_accountable_type
    @return_to = safe_return_to_path
    @fio_item = requested_fio_item

    unless @fio_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @fio_account = @fio_item.fio_accounts.unlinked.first
    @discovered_account = @fio_item.fio_account
    @account_type_options = account_type_options

    render layout: false
  end

  # Create a new Sure account for the connection's account and link the two.
  def link_accounts
    fio_item = requested_fio_item
    unless fio_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    account_type = requested_accountable_type
    unless Provider::FioAdapter.supported_account_types.include?(account_type)
      redirect_to new_account_path, alert: t(".unsupported_account_type")
      return
    end

    fio_account = fio_item.fio_accounts.unlinked.first
    unless fio_account
      redirect_to select_accounts_fio_items_path(fio_item_id: fio_item.id, accountable_type: account_type, return_to: safe_return_to_path), alert: t(".no_account_found")
      return
    end

    account = nil
    ActiveRecord::Base.transaction do
      account = create_account_from_fio(fio_account, account_type)
      AccountProvider.create!(account: account, provider: fio_account)
    end

    fio_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name)
  rescue ActiveRecord::RecordNotUnique
    # A concurrent submit linked the account first; the transaction rolled this one back,
    # so send the user back to the screen rather than a 500.
    redirect_to select_accounts_fio_items_path(fio_item_id: fio_item.id, accountable_type: params[:accountable_type], return_to: safe_return_to_path), alert: t(".link_failed")
  end

  # Render the confirmation screen for attaching the connection's account to an existing
  # Sure account.
  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    @fio_item = requested_fio_item
    unless @fio_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @fio_account = @fio_item.fio_accounts.unlinked.first
    @discovered_account = @fio_item.fio_account
    @return_to = safe_return_to_path

    render layout: false
  end

  # Link the connection's account to an existing Sure account and sync.
  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    fio_item = requested_fio_item

    unless fio_item.credentials_configured?
      redirect_to settings_providers_path, alert: t("fio_items.select_existing_account.no_credentials_configured")
      return
    end

    fio_account = fio_item.fio_accounts.find_by(id: params[:fio_account_id])
    unless fio_account
      redirect_to accounts_path, alert: t(".no_account_selected")
      return
    end

    if account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    if fio_account.account_provider.present?
      redirect_to accounts_path, alert: t(".fio_account_already_linked")
      return
    end

    # Fio can only describe the account types the adapter claims to support, so linking
    # its statement to, say, a Crypto account would feed it balances it cannot represent.
    # link_accounts and complete_account_setup already refuse this for new accounts.
    unless Provider::FioAdapter.supported_account_types.include?(account.accountable_type)
      redirect_to accounts_path, alert: t(".unsupported_account_type")
      return
    end

    begin
      AccountProvider.create!(account: account, provider: fio_account)
    rescue ActiveRecord::RecordNotUnique
      # The two guards above are reads; a double submit gets both requests past them and
      # the unique indexes on account_providers are what actually settle it. The request
      # that loses that race gets the same answer the guard would have given it.
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    fio_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name)
  end

  # Render the post-sync setup screen while the account still needs a decision.
  def setup_accounts
    @fio_account = @fio_item.fio_accounts.needs_setup.first
    @discovered_account = @fio_item.fio_account
    @return_to = safe_return_to_path
    @account_type_options = [ [ t(".account_types.skip"), "skip" ] ] + account_type_options
    @selected_account_type = @fio_account&.suggested_account_type || "skip"
  end

  # Apply the user's setup choice: create and link a Sure account, or skip.
  def complete_account_setup
    fio_account = @fio_item.fio_accounts.needs_setup.first
    unless fio_account
      redirect_to accounts_path, alert: t(".no_account"), status: :see_other
      return
    end

    selected_type = params[:account_type].to_s
    if selected_type.blank? || selected_type == "skip"
      # Persist the skip so the account stops resurfacing as "needs setup" on every sync.
      fio_account.update!(ignored: true)
      redirect_to accounts_path, notice: t(".skipped"), status: :see_other
      return
    end

    unless Provider::FioAdapter.supported_account_types.include?(selected_type)
      redirect_to setup_accounts_fio_item_path(@fio_item), alert: t(".unsupported_account_type"), status: :see_other
      return
    end

    account = nil
    ActiveRecord::Base.transaction do
      account = create_account_from_fio(fio_account, selected_type)
      AccountProvider.create!(account: account, provider: fio_account)
    end

    @fio_item.sync_later

    redirect_to safe_return_to_path || accounts_path, notice: t(".success", account_name: account.name), status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::RecordNotUnique => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Fio account setup failed",
      source: self.class.name,
      provider_key: "fio",
      family: @fio_item&.family,
      metadata: { fio_item_id: @fio_item&.id, error_class: e.class.name, error_message: e.message }
    )
    redirect_to accounts_path, alert: t(".creation_failed"), status: :see_other
  end

  private

    # Load the requested item scoped to the current family.
    def set_fio_item
      @fio_item = Current.family.fio_items.find(params[:id])
    end

    # Strong params for creating/updating a connection.
    def fio_item_params
      params.require(:fio_item).permit(:name, :sync_start_date, :token)
    end

    # Params for update: a stripped token, or none at all so a blank field keeps the
    # token already on file.
    def update_params
      permitted = fio_item_params
      token = permitted[:token].to_s.strip

      token.present? ? permitted.merge(token: token) : permitted.except(:token)
    end

    # True when an update is a fresh attempt at the account's history: a replacement
    # token, or a start date that actually differs from the one on file.
    def history_attempt_renewed?(attributes)
      return true if attributes[:token].present?

      attributes.key?(:sync_start_date) &&
        attributes[:sync_start_date].to_s != @fio_item.sync_start_date.to_s
    end

    # Load the active item referenced by fio_item_id, scoped to the family.
    def requested_fio_item
      Current.family.fio_items.active.find_by!(id: params[:fio_item_id])
    end

    # The account type the user picked, defaulting to Fio's current-account suggestion.
    def requested_accountable_type
      params[:accountable_type].presence || FioAccount::DEFAULT_ACCOUNTABLE_TYPE
    end

    # Selectable account types for the setup screens.
    def account_type_options
      Provider::FioAdapter.supported_account_types.map do |type|
        [ t("fio_items.account_types.#{type.underscore}"), type ]
      end
    end

    # Create and sync a Sure account from the Fio account's statement header.
    def create_account_from_fio(fio_account, account_type)
      # Linking clears any prior skip so a future unlink re-prompts for setup.
      fio_account.update!(ignored: false) if fio_account.ignored?

      # Same normalization FioAccount::Processor applies: Fio reports a drawn loan or
      # overdraft negative, Sure holds a liability positive. Without it the new account
      # shows a negative debt until a sync corrects it, and the next sync may well be
      # throttled — discovery just used the token.
      balance = fio_account.current_balance || 0
      balance = balance.abs if account_type == "Loan"
      subtype = fio_account.suggested_subtype if account_type == fio_account.suggested_account_type

      Account.create_and_sync(
        {
          family: Current.family,
          name: fio_account.name,
          balance: balance,
          cash_balance: balance,
          currency: fio_account.currency,
          accountable_type: account_type,
          accountable_attributes: subtype.present? ? { subtype: subtype } : {}
        },
        skip_initial_sync: true
      )
    end

    # Re-render the providers settings panel (Turbo) or redirect with a flash.
    def render_provider_panel(flash_type, message)
      if turbo_frame_request?
        flash.now[flash_type] = message
        @fio_items = Current.family.fio_items.active.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "fio-providers-panel",
            partial: "settings/providers/fio_panel",
            locals: { fio_items: @fio_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, { flash_type => message, status: :see_other }
      end
    end

    # Re-render the providers panel with an error (Turbo) or redirect with alert.
    def render_provider_panel_error(message)
      @error_message = message
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "fio-providers-panel",
          partial: "settings/providers/fio_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end

    # Validate the return_to param as a safe in-app relative path, or nil.
    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s.strip
      return nil unless return_to.start_with?("/")
      return nil if return_to[1] == "/" || return_to[1] == "\\"
      return nil if return_to.include?("\\") || return_to.match?(/[[:cntrl:]]/)
      return nil if encoded_path_separator?(return_to)

      uri = URI.parse(return_to)
      return nil unless uri.relative?

      Rails.application.routes.recognize_path(uri.path, method: :get)

      return_to
    rescue URI::InvalidURIError, ActionController::RoutingError
      nil
    end

    # True if the path's second char is a percent-encoded slash/backslash
    # (used to block protocol-relative redirect bypasses).
    def encoded_path_separator?(return_to)
      encoded_second_character = return_to[1, 3]
      return false unless encoded_second_character&.start_with?("%")

      decoded = URI.decode_www_form_component(encoded_second_character)
      decoded == "/" || decoded == "\\"
    rescue ArgumentError
      true
    end
end
