class MercuryItemsController < ApplicationController
  include RetiredProviderRouting
  self.retired_provider_key = "mercury"

  before_action :set_mercury_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :new, :create, :preload_accounts, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  rescue_from(*MercuryItem::LegacyAccess::DENIAL_ERRORS, with: :render_ownership_changed)
  rescue_from ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, with: :render_ownership_changed

  def index
    @mercury_items = Current.family.mercury_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  # Preload Mercury accounts in background (async, non-blocking)
  def preload_accounts
    begin
      account_flow = mercury_item_account_flow_context
      mercury_item = account_flow[:mercury_item]
      unless mercury_item
        render json: mercury_item_selection_error_payload(account_flow[:credentialed_items])
        return
      end

      unless mercury_item.credentials_configured?
        render json: { success: false, error: "no_credentials", has_accounts: false }
        return
      end

      result = lifecycle(mercury_item).discover
      render json: { success: true, has_accounts: result[:accounts].any?, cached: result[:cached] }
    rescue *MercuryItem::LegacyAccess::DENIAL_ERRORS
      raise
    rescue Provider::Mercury::MercuryError => e
      capture_lifecycle_failure(e)
      # API error (bad token, network issue, etc) - keep button visible, show error when clicked
      render json: { success: false, error: "api_error", error_message: t("mercury_items.lifecycle.unavailable"), has_accounts: nil }
    rescue StandardError => e
      capture_lifecycle_failure(e)
      # Unexpected error - keep button visible, show error when clicked
      render json: { success: false, error: "unexpected_error", error_message: t("mercury_items.lifecycle.unavailable"), has_accounts: nil }
    end
  end

  # Fetch available accounts from Mercury API and show selection UI
  def select_accounts
    begin
      account_flow = mercury_item_account_flow_context
      @mercury_item = account_flow[:mercury_item]
      unless @mercury_item
        render_mercury_item_selection_failure(credentialed_items: account_flow[:credentialed_items])
        return
      end

      result = lifecycle(@mercury_item).discover(flow: :link_accounts)
      @mercury_item = result[:item]
      @available_accounts = result[:accounts]
      @selection_token = result[:selection_token]
      @accountable_type = params[:accountable_type] || "Depository"
      @return_to = safe_return_to_path

      if @available_accounts.empty?
        redirect_to new_account_path, alert: t(".no_accounts_found")
        return
      end

      render layout: false
    rescue *MercuryItem::LegacyAccess::DENIAL_ERRORS
      raise
    rescue Provider::Mercury::MercuryError => e
      capture_lifecycle_failure(e)
      @error_message = t("mercury_items.lifecycle.unavailable")
      @return_path = safe_return_to_path
      render partial: "mercury_items/api_error",
             locals: { error_message: @error_message, return_path: @return_path },
             layout: false
    rescue StandardError => e
      capture_lifecycle_failure(e)
      @error_message = t("mercury_items.lifecycle.unavailable")
      @return_path = safe_return_to_path
      render partial: "mercury_items/api_error",
             locals: { error_message: @error_message, return_path: @return_path },
             layout: false
    end
  end

  # Create accounts from selected Mercury accounts
  def link_accounts
    selected_account_ids = params[:account_ids] || []
    accountable_type = params[:accountable_type] || "Depository"
    return_to = safe_return_to_path

    if selected_account_ids.empty?
      redirect_to new_account_path, alert: t(".no_accounts_selected")
      return
    end

    mercury_item = explicit_mercury_item
    unless mercury_item
      redirect_to settings_providers_path, alert: t(".select_connection", default: "Choose a Mercury connection before linking accounts.")
      return
    end
    selection = MercuryItem::Selection.from_token(params[:selection_token], flow: :link_accounts)
    result = lifecycle(mercury_item).link_accounts(account_ids: selected_account_ids, account_type: accountable_type, selection: selection)
    created_accounts = result[:created_accounts]
    already_linked_accounts = result[:already_linked_accounts]
    invalid_accounts = result[:invalid_accounts]
    # Build appropriate flash message
    if invalid_accounts.any? && created_accounts.empty? && already_linked_accounts.empty?
      # All selected accounts were invalid (blank names)
      redirect_to new_account_path, alert: t(".invalid_account_names", count: invalid_accounts.count)
    elsif invalid_accounts.any? && (created_accounts.any? || already_linked_accounts.any?)
      # Some accounts were created/already linked, but some had invalid names
      redirect_to return_to || accounts_path,
                  alert: t(".partial_invalid",
                           created_count: created_accounts.count,
                           already_linked_count: already_linked_accounts.count,
                           invalid_count: invalid_accounts.count)
    elsif created_accounts.any? && already_linked_accounts.any?
      redirect_to return_to || accounts_path,
                  notice: t(".partial_success",
                           created_count: created_accounts.count,
                           already_linked_count: already_linked_accounts.count,
                           already_linked_names: already_linked_accounts.join(", "))
    elsif created_accounts.any?
      redirect_to return_to || accounts_path,
                  notice: t(".success", count: created_accounts.count)
    elsif already_linked_accounts.any?
      redirect_to return_to || accounts_path,
                  alert: t(".all_already_linked",
                          count: already_linked_accounts.count,
                          names: already_linked_accounts.join(", "))
    else
      redirect_to new_account_path, alert: t(".link_failed")
    end
  rescue Provider::Mercury::MercuryError => e
    capture_lifecycle_failure(e)
    redirect_to new_account_path, alert: t("mercury_items.lifecycle.unavailable")
  end

  # Fetch available Mercury accounts to link with an existing account
  def select_existing_account
    account_id = params[:account_id]

    unless account_id.present?
      redirect_to accounts_path, alert: t(".no_account_specified")
      return
    end

    @account = Current.family.accounts.find(account_id)

    # Check if account is already linked
    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    account_flow = mercury_item_account_flow_context
    @mercury_item = account_flow[:mercury_item]
    unless @mercury_item
      render_mercury_item_selection_failure(credentialed_items: account_flow[:credentialed_items])
      return
    end

    begin
      result = lifecycle(@mercury_item).discover(flow: :link_existing_account, account_id: @account.id)
      @mercury_item = result[:item]
      @available_accounts = result[:accounts]
      @selection_token = result[:selection_token]
      if @available_accounts.empty?
        redirect_to accounts_path, alert: t(".all_accounts_already_linked")
        return
      end
      @return_to = safe_return_to_path

      render layout: false
    rescue *MercuryItem::LegacyAccess::DENIAL_ERRORS
      raise
    rescue Provider::Mercury::MercuryError => e
      capture_lifecycle_failure(e)
      @error_message = t("mercury_items.lifecycle.unavailable")
      render partial: "mercury_items/api_error",
             locals: { error_message: @error_message, return_path: accounts_path },
             layout: false
    rescue StandardError => e
      capture_lifecycle_failure(e)
      @error_message = t("mercury_items.lifecycle.unavailable")
      render partial: "mercury_items/api_error",
             locals: { error_message: @error_message, return_path: accounts_path },
             layout: false
    end
  end

  # Link a selected Mercury account to an existing account
  def link_existing_account
    account_id = params[:account_id]
    mercury_account_id = params[:mercury_account_id]
    return_to = safe_return_to_path

    unless account_id.present? && mercury_account_id.present?
      redirect_to accounts_path, alert: t(".missing_parameters")
      return
    end

    mercury_item = explicit_mercury_item
    unless mercury_item
      redirect_to settings_providers_path, alert: t(".select_connection", default: "Choose a Mercury connection before linking accounts.")
      return
    end
    selection = MercuryItem::Selection.from_token(params[:selection_token], flow: :link_existing_account, account_id: account_id)
    result = lifecycle(mercury_item).link_existing_account(account_id: account_id, mercury_account_id: mercury_account_id, selection: selection)
    if result[:error]
      redirect_to accounts_path, alert: t(".#{result[:error]}")
      return
    end
    @account = result.fetch(:account)
    redirect_to return_to || accounts_path,
                notice: t(".success", account_name: @account.name)
  rescue Provider::Mercury::MercuryError => e
    capture_lifecycle_failure(e)
    redirect_to accounts_path, alert: t("mercury_items.lifecycle.unavailable")
  end

  def new
    @mercury_item = Current.family.mercury_items.build
  end

  def create
    @mercury_item = MercuryItem::Lifecycle.create(family: Current.family, actor: Current.user, attributes: mercury_item_params)
    if @mercury_item.persisted?
      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @mercury_items = Current.family.mercury_items.active.ordered.includes(:syncs, :mercury_accounts)
        render turbo_stream: [
          turbo_stream.replace(
            "mercury-providers-panel",
            partial: "settings/providers/mercury_panel",
            locals: { mercury_items: @mercury_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @mercury_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "mercury-providers-panel",
          partial: "settings/providers/mercury_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        render :new, status: :unprocessable_entity
      end
    end
  end

  def edit
    connection = Current.family.provider_connections.where(provider_key: "mercury")
      .joins(:provider_migration_control).find_by(provider_migration_controls: {
        family_id: Current.family.id, legacy_type: "MercuryItem", legacy_id: @mercury_item.id, state: ProviderMigrationControl::NATIVE_STATES
      })
    redirect_to edit_provider_connection_path(connection) if connection
  end

  def update
    @mercury_item = lifecycle(@mercury_item).update_settings(mercury_item_params)
    if @mercury_item.errors.empty?
      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @mercury_items = Current.family.mercury_items.active.ordered.includes(:syncs, :mercury_accounts)
        render turbo_stream: [
          turbo_stream.replace(
            "mercury-providers-panel",
            partial: "settings/providers/mercury_panel",
            locals: { mercury_items: @mercury_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @mercury_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "mercury-providers-panel",
          partial: "settings/providers/mercury_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end

  def destroy
    lifecycle(@mercury_item).disconnect
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    MercuryItem::SyncRequest.new(item: @mercury_item, actor: Current.user).call

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Show unlinked Mercury accounts for setup
  def setup_accounts
    # First, ensure we have the latest accounts from the API
    @api_error = fetch_mercury_accounts_from_api

    # Get Mercury accounts that are not linked (no AccountProvider)
    @mercury_accounts = @mercury_item.mercury_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    # Get supported account types from the adapter
    supported_types = Provider::MercuryAdapter.supported_account_types

    # Map of account type keys to their internal values
    account_type_keys = {
      "depository" => "Depository",
      "credit_card" => "CreditCard",
      "investment" => "Investment",
      "loan" => "Loan",
      "other_asset" => "OtherAsset"
    }

    # Build account type options using i18n, filtering to supported types
    all_account_type_options = account_type_keys.filter_map do |key, type|
      next unless supported_types.include?(type)
      [ t(".account_types.#{key}"), type ]
    end

    # Add "Skip" option at the beginning
    @account_type_options = [ [ t(".account_types.skip"), "skip" ] ] + all_account_type_options

    # Helper to translate subtype options
    translate_subtypes = ->(type_key, subtypes_hash) {
      subtypes_hash.map { |k, v| [ t(".subtypes.#{type_key}.#{k}", default: v[:long] || k.humanize), k ] }
    }

    # Subtype options for each account type (only include supported types)
    all_subtype_options = {
      "Depository" => {
        label: t(".subtype_labels.depository"),
        options: translate_subtypes.call("depository", Depository::SUBTYPES)
      },
      "CreditCard" => {
        label: t(".subtype_labels.credit_card"),
        options: [],
        message: t(".subtype_messages.credit_card")
      },
      "Investment" => {
        label: t(".subtype_labels.investment"),
        options: translate_subtypes.call("investment", Investment::SUBTYPES)
      },
      "Loan" => {
        label: t(".subtype_labels.loan"),
        options: translate_subtypes.call("loan", Loan::SUBTYPES)
      },
      "OtherAsset" => {
        label: t(".subtype_labels.other_asset").presence,
        options: [],
        message: t(".subtype_messages.other_asset")
      }
    }

    @subtype_options = all_subtype_options.slice(*supported_types)
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}

    selection = MercuryItem::Selection.from_token(params[:selection_token], flow: :complete_account_setup)
    result = lifecycle(@mercury_item).complete_account_setup(account_types: account_types, account_subtypes: account_subtypes, selection: selection)
    created_accounts = result[:created_accounts]
    skipped_count = result[:skipped_count]
    # Set appropriate flash message
    if created_accounts.any?
      flash[:notice] = t(".success", count: created_accounts.count)
    elsif skipped_count > 0
      flash[:notice] = t(".all_skipped")
    else
      flash[:notice] = t(".no_accounts")
    end

    if turbo_frame_request?
      # Recompute data needed by Accounts#index partials
      @manual_accounts = Account.uncached {
        Current.family.accounts
          .visible_manual
          .order(:name)
          .to_a
      }
      @mercury_items = Current.family.mercury_items.ordered

      manual_accounts_stream = if @manual_accounts.any?
        turbo_stream.update(
          "manual-accounts",
          partial: "accounts/index/manual_accounts",
          locals: { accounts: @manual_accounts }
        )
      else
        turbo_stream.replace("manual-accounts", view_context.tag.div(id: "manual-accounts"))
      end

      render turbo_stream: [
        manual_accounts_stream,
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@mercury_item),
          partial: "mercury_items/mercury_item",
          locals: { mercury_item: @mercury_item }
        )
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    # Fetch Mercury accounts from the API and store them locally
    # Returns nil on success, or an error message string on failure
    def fetch_mercury_accounts_from_api
      result = lifecycle(@mercury_item).discover(flow: :complete_account_setup, setup: true)
      @mercury_item = result[:item]
      @selection_token = result[:selection_token]
      nil
    rescue *MercuryItem::LegacyAccess::DENIAL_ERRORS
      raise
    rescue StandardError => error
      capture_lifecycle_failure(error)
      # An unavailable API never issues a token for an unreviewed connection.
      t("mercury_items.lifecycle.unavailable")
    end

    def lifecycle(item)
      MercuryItem::Lifecycle.new(item: item, actor: Current.user)
    end

    def explicit_mercury_item
      Current.family.mercury_items.find(params[:mercury_item_id]) if params[:mercury_item_id].present?
    end

    def render_ownership_changed(error)
      capture_lifecycle_failure(error)
      if action_name == "preload_accounts"
        render json: { success: false, error: "ownership_changed", error_message: t("mercury_items.lifecycle.unavailable"), has_accounts: nil }, status: :conflict
      else
        redirect_to settings_providers_path, alert: t("mercury_items.lifecycle.unavailable"), status: :see_other
      end
    end

    def capture_lifecycle_failure(error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warning", message: "Mercury connection management failed",
        source: self.class.name, provider_key: "mercury", family: Current.family,
        metadata: { action: action_name, mercury_item_id: @mercury_item&.id, error_class: error.class.name })
    rescue StandardError
      nil
    end
    def set_mercury_item
      @mercury_item = Current.family.mercury_items.find(params[:id])
    end

    def mercury_item_params
      permitted = params.require(:mercury_item).permit(:name, :sync_start_date, :token, :base_url)
      permitted.delete(:token) if @mercury_item&.persisted? && permitted[:token].blank?
      permitted
    end

    def mercury_items_with_credentials
      Current.family.mercury_items.active.ordered.select(&:credentials_configured?)
    end

    def mercury_item_account_flow_context
      credentialed_items = mercury_items_with_credentials
      mercury_item = nil

      if params[:mercury_item_id].present?
        mercury_item = credentialed_items.find { |item| item.id.to_s == params[:mercury_item_id].to_s }
      elsif credentialed_items.one?
        mercury_item = credentialed_items.first
      end

      {
        mercury_item: mercury_item,
        credentialed_items: credentialed_items
      }
    end

    def mercury_item_selection_error_payload(credentialed_items)
      if mercury_item_selection_required?(credentialed_items)
        {
          success: false,
          error: "select_connection",
          error_message: t(".select_connection", default: "Choose a Mercury connection before loading accounts."),
          has_accounts: nil
        }
      else
        { success: false, error: "no_credentials", has_accounts: false }
      end
    end

    def render_mercury_item_selection_failure(credentialed_items:)
      if mercury_item_selection_required?(credentialed_items)
        redirect_to settings_providers_path,
                    alert: t(".select_connection", default: "Choose a Mercury connection in Provider Settings.")
      elsif turbo_frame_request?
        render partial: "mercury_items/setup_required", layout: false
      else
        redirect_to settings_providers_path,
                    alert: t(".no_credentials_configured",
                             default: "Please configure your Mercury API token first in Provider Settings.")
      end
    end

    def mercury_item_selection_required?(credentialed_items)
      credentialed_items.count > 1 && params[:mercury_item_id].blank?
    end

    # Sanitize return_to parameter to prevent XSS attacks
    # Only allow internal paths, reject external URLs and javascript: URIs
    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s

      # Parse the URL to check if it's external
      begin
        uri = URI.parse(return_to)

        # Reject absolute URLs with schemes (http:, https:, javascript:, etc.)
        # Only allow relative paths
        return nil if uri.scheme.present?

        # Ensure the path starts with / (is a relative path)
        return nil unless return_to.start_with?("/")

        return_to
      rescue URI::InvalidURIError
        # If the URI is invalid, reject it
        nil
      end
    end
end
