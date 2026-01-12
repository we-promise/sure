class LunchflowItemsController < ApplicationController
  before_action :set_lunchflow_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @lunchflow_items = Current.family.lunchflow_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  # Preload Lunchflow accounts in background (async, non-blocking)
  def preload_accounts
    begin
      # Check if family has credentials
      unless Current.family.has_lunchflow_credentials?
        render json: { success: false, error: "no_credentials", has_accounts: false }
        return
      end

      cache_key = "lunchflow_accounts_#{Current.family.id}"

      # Check if already cached
      cached_accounts = Rails.cache.read(cache_key)

      if cached_accounts.present?
        render json: { success: true, has_accounts: cached_accounts.any?, cached: true }
        return
      end

      # Fetch from API
      lunchflow_provider = Provider::LunchflowAdapter.build_provider(family: Current.family)

      unless lunchflow_provider.present?
        render json: { success: false, error: "no_api_key", has_accounts: false }
        return
      end

      accounts_data = lunchflow_provider.get_accounts
      available_accounts = accounts_data[:accounts] || []

      # Cache the accounts for 5 minutes
      Rails.cache.write(cache_key, available_accounts, expires_in: 5.minutes)

      render json: { success: true, has_accounts: available_accounts.any?, cached: false }
    rescue Provider::Lunchflow::LunchflowError => e
      Rails.logger.error("Lunchflow preload error: #{e.message}")
      # API error (bad key, network issue, etc) - keep button visible, show error when clicked
      render json: { success: false, error: "api_error", error_message: e.message, has_accounts: nil }
    rescue StandardError => e
      Rails.logger.error("Unexpected error preloading Lunchflow accounts: #{e.class}: #{e.message}")
      # Unexpected error - keep button visible, show error when clicked
      render json: { success: false, error: "unexpected_error", error_message: e.message, has_accounts: nil }
    end
  end

  # Fetch available accounts from Lunchflow API and show selection UI
  def select_accounts
    begin
      # Check if family has Lunchflow credentials configured
      unless Current.family.has_lunchflow_credentials?
        if turbo_frame_request?
          # Render setup modal for turbo frame requests
          render partial: "lunchflow_items/setup_required", layout: false
        else
          # Redirect for regular requests
          redirect_to settings_providers_path,
                     alert: t(".no_credentials_configured",
                            default: "Please configure your Lunch Flow API key first in Provider Settings.")
        end
        return
      end

      cache_key = "lunchflow_accounts_#{Current.family.id}"

      # Try to get cached accounts first
      @available_accounts = Rails.cache.read(cache_key)

      # If not cached, fetch from API
      if @available_accounts.nil?
        lunchflow_provider = Provider::LunchflowAdapter.build_provider(family: Current.family)

        unless lunchflow_provider.present?
          redirect_to settings_providers_path, alert: t(".no_api_key",
                                                        default: "Lunch Flow API key not found. Please configure it in Provider Settings.")
          return
        end

        accounts_data = lunchflow_provider.get_accounts

        @available_accounts = accounts_data[:accounts] || []

        # Cache the accounts for 5 minutes
        Rails.cache.write(cache_key, @available_accounts, expires_in: 5.minutes)
      end

      # Filter out already linked accounts
      lunchflow_item = Current.family.lunchflow_items.first
      if lunchflow_item
        linked_account_ids = lunchflow_item.lunchflow_accounts.joins(:account_provider).pluck(:account_id)
        @available_accounts = @available_accounts.reject { |acc| linked_account_ids.include?(acc[:id].to_s) }
      end

      @accountable_type = params[:accountable_type] || "Depository"
      @return_to = safe_return_to_path

      if @available_accounts.empty?
        redirect_to new_account_path, alert: t(".no_accounts_found")
        return
      end

      render layout: false
    rescue Provider::Lunchflow::LunchflowError => e
      Rails.logger.error("Lunch flow API error in select_accounts: #{e.message}")
      @error_message = e.message
      @return_path = safe_return_to_path
      render partial: "lunchflow_items/api_error",
             locals: { error_message: @error_message, return_path: @return_path },
             layout: false
    rescue StandardError => e
      Rails.logger.error("Unexpected error in select_accounts: #{e.class}: #{e.message}")
      @error_message = "An unexpected error occurred. Please try again later."
      @return_path = safe_return_to_path
      render partial: "lunchflow_items/api_error",
             locals: { error_message: @error_message, return_path: @return_path },
             layout: false
    end
  end

  # Create accounts from selected Lunchflow accounts
  def link_accounts
    selected_account_ids = params[:account_ids] || []
    accountable_type = params[:accountable_type] || "Depository"
    return_to = safe_return_to_path

    if selected_account_ids.empty?
      redirect_to new_account_path, alert: t(".no_accounts_selected")
      return
    end

    # Create or find lunchflow_item for this family
    lunchflow_item = Current.family.lunchflow_items.first_or_create!(
      name: "Lunch Flow Connection"
    )

    # Fetch account details from API
    lunchflow_provider = Provider::LunchflowAdapter.build_provider(family: Current.family)
    unless lunchflow_provider.present?
      redirect_to new_account_path, alert: t(".no_api_key")
      return
    end

    accounts_data = lunchflow_provider.get_accounts

    created_accounts = []
    already_linked_accounts = []
    invalid_accounts = []

    selected_account_ids.each do |account_id|
      # Find the account data from API response
      account_data = accounts_data[:accounts].find { |acc| acc[:id].to_s == account_id.to_s }
      next unless account_data

      # Validate account name is not blank (required by Account model)
      if account_data[:name].blank?
        invalid_accounts << account_id
        Rails.logger.warn "LunchflowItemsController - Skipping account #{account_id} with blank name"
        next
      end

      # Create or find lunchflow_account
      lunchflow_account = lunchflow_item.lunchflow_accounts.find_or_initialize_by(
        account_id: account_id.to_s
      )
      lunchflow_account.upsert_lunchflow_snapshot!(account_data)
      lunchflow_account.save!

      # Check if this lunchflow_account is already linked
      if lunchflow_account.account_provider.present?
        already_linked_accounts << account_data[:name]
        next
      end

      # Create the internal Account with proper balance initialization
      # Use lunchflow_account.currency (already parsed) and skip initial sync
      # because the provider sync will set the correct currency from the balance API
      account = Account.create_and_sync(
        {
          family: Current.family,
          name: account_data[:name],
          balance: 0, # Initial balance will be set during sync
          currency: lunchflow_account.currency || "USD",
          accountable_type: accountable_type,
          accountable_attributes: {}
        },
        skip_initial_sync: true
      )

      # Link account to lunchflow_account via account_providers join table
      AccountProvider.create!(
        account: account,
        provider: lunchflow_account
      )

      created_accounts << account
    end

    # Trigger sync to fetch transactions if any accounts were created
    lunchflow_item.sync_later if created_accounts.any?

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
  rescue Provider::Lunchflow::LunchflowError => e
    redirect_to new_account_path, alert: t(".api_error", message: e.message)
  end

  # Fetch available Lunchflow accounts to link with an existing account
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

    # Check if family has Lunchflow credentials configured
    unless Current.family.has_lunchflow_credentials?
      if turbo_frame_request?
        # Render setup modal for turbo frame requests
        render partial: "lunchflow_items/setup_required", layout: false
      else
        # Redirect for regular requests
        redirect_to settings_providers_path,
                   alert: t(".no_credentials_configured",
                          default: "Please configure your Lunch Flow API key first in Provider Settings.")
      end
      return
    end

    begin
      cache_key = "lunchflow_accounts_#{Current.family.id}"

      # Try to get cached accounts first
      @available_accounts = Rails.cache.read(cache_key)

      # If not cached, fetch from API
      if @available_accounts.nil?
        lunchflow_provider = Provider::LunchflowAdapter.build_provider(family: Current.family)

        unless lunchflow_provider.present?
          redirect_to settings_providers_path, alert: t(".no_api_key",
                                                        default: "Lunch Flow API key not found. Please configure it in Provider Settings.")
          return
        end

        accounts_data = lunchflow_provider.get_accounts

        @available_accounts = accounts_data[:accounts] || []

        # Cache the accounts for 5 minutes
        Rails.cache.write(cache_key, @available_accounts, expires_in: 5.minutes)
      end

      if @available_accounts.empty?
        redirect_to accounts_path, alert: t(".no_accounts_found")
        return
      end

      # Filter out already linked accounts
      lunchflow_item = Current.family.lunchflow_items.first
      if lunchflow_item
        linked_account_ids = lunchflow_item.lunchflow_accounts.joins(:account_provider).pluck(:account_id)
        @available_accounts = @available_accounts.reject { |acc| linked_account_ids.include?(acc[:id].to_s) }
      end

      if @available_accounts.empty?
        redirect_to accounts_path, alert: t(".all_accounts_already_linked")
        return
      end

      @return_to = safe_return_to_path

      render layout: false
    rescue Provider::Lunchflow::LunchflowError => e
      Rails.logger.error("Lunch flow API error in select_existing_account: #{e.message}")
      @error_message = e.message
      render partial: "lunchflow_items/api_error",
             locals: { error_message: @error_message, return_path: accounts_path },
             layout: false
    rescue StandardError => e
      Rails.logger.error("Unexpected error in select_existing_account: #{e.class}: #{e.message}")
      @error_message = "An unexpected error occurred. Please try again later."
      render partial: "lunchflow_items/api_error",
             locals: { error_message: @error_message, return_path: accounts_path },
             layout: false
    end
  end

  # Link a selected Lunchflow account to an existing account
  def link_existing_account
    account_id = params[:account_id]
    lunchflow_account_id = params[:lunchflow_account_id]
    return_to = safe_return_to_path

    unless account_id.present? && lunchflow_account_id.present?
      redirect_to accounts_path, alert: t(".missing_parameters")
      return
    end

    @account = Current.family.accounts.find(account_id)

    # Check if account is already linked
    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    # Create or find lunchflow_item for this family
    lunchflow_item = Current.family.lunchflow_items.first_or_create!(
      name: "Lunch Flow Connection"
    )

    # Fetch account details from API
    lunchflow_provider = Provider::LunchflowAdapter.build_provider(family: Current.family)
    unless lunchflow_provider.present?
      redirect_to accounts_path, alert: t(".no_api_key")
      return
    end

    accounts_data = lunchflow_provider.get_accounts

    # Find the selected Lunchflow account data
    account_data = accounts_data[:accounts].find { |acc| acc[:id].to_s == lunchflow_account_id.to_s }
    unless account_data
      redirect_to accounts_path, alert: t(".lunchflow_account_not_found")
      return
    end

    # Validate account name is not blank (required by Account model)
    if account_data[:name].blank?
      redirect_to accounts_path, alert: t(".invalid_account_name")
      return
    end

    # Create or find lunchflow_account
    lunchflow_account = lunchflow_item.lunchflow_accounts.find_or_initialize_by(
      account_id: lunchflow_account_id.to_s
    )
    lunchflow_account.upsert_lunchflow_snapshot!(account_data)
    lunchflow_account.save!

    # Check if this lunchflow_account is already linked to another account
    if lunchflow_account.account_provider.present?
      redirect_to accounts_path, alert: t(".lunchflow_account_already_linked")
      return
    end

    # Link account to lunchflow_account via account_providers join table
    AccountProvider.create!(
      account: @account,
      provider: lunchflow_account
    )

    # Trigger sync to fetch transactions
    lunchflow_item.sync_later

    redirect_to return_to || accounts_path,
                notice: t(".success", account_name: @account.name)
  rescue Provider::Lunchflow::LunchflowError => e
    redirect_to accounts_path, alert: t(".api_error", message: e.message)
  end

  def new
    @lunchflow_item = Current.family.lunchflow_items.build
  end

  def create
    @lunchflow_item = Current.family.lunchflow_items.build(lunchflow_params)
    @lunchflow_item.name ||= "Lunch Flow Connection"

    if @lunchflow_item.save
      # Trigger initial sync to fetch accounts
      @lunchflow_item.sync_later

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @lunchflow_items = Current.family.lunchflow_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "lunchflow-providers-panel",
            partial: "settings/providers/lunchflow_panel",
            locals: { lunchflow_items: @lunchflow_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @lunchflow_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "lunchflow-providers-panel",
          partial: "settings/providers/lunchflow_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        render :new, status: :unprocessable_entity
      end
    end
  end

  def edit
  end

  def update
    if @lunchflow_item.update(lunchflow_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @lunchflow_items = Current.family.lunchflow_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "lunchflow-providers-panel",
            partial: "settings/providers/lunchflow_panel",
            locals: { lunchflow_items: @lunchflow_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @lunchflow_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "lunchflow-providers-panel",
          partial: "settings/providers/lunchflow_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end

  def destroy
    # Ensure we detach provider links before scheduling deletion
    begin
      @lunchflow_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("LunchFlow unlink during destroy failed: #{e.class} - #{e.message}")
    end
    @lunchflow_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    unless @lunchflow_item.syncing?
      @lunchflow_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Show unlinked Lunchflow accounts for setup (similar to SimpleFIN setup_accounts)
  def setup_accounts
    # First, ensure we have the latest accounts from the API
    @api_error = fetch_lunchflow_accounts_from_api

    # Get Lunchflow accounts that are not linked (no AccountProvider)
    @lunchflow_accounts = @lunchflow_item.lunchflow_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    # Get supported account types from the adapter
    supported_types = Provider::LunchflowAdapter.supported_account_types

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
      subtypes_hash.keys.map { |k| [ t(".subtypes.#{type_key}.#{k}"), k ] }
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

    # Valid account types for this provider
    valid_types = Provider::LunchflowAdapter.supported_account_types

    created_accounts = []
    skipped_count = 0

    begin
      ActiveRecord::Base.transaction do
        account_types.each do |lunchflow_account_id, selected_type|
          # Skip accounts marked as "skip"
          if selected_type == "skip" || selected_type.blank?
            skipped_count += 1
            next
          end

          # Validate account type is supported
          unless valid_types.include?(selected_type)
            Rails.logger.warn("Invalid account type '#{selected_type}' submitted for LunchFlow account #{lunchflow_account_id}")
            next
          end

          # Find account - scoped to this item to prevent cross-item manipulation
          lunchflow_account = @lunchflow_item.lunchflow_accounts.find_by(id: lunchflow_account_id)
          unless lunchflow_account
            Rails.logger.warn("LunchFlow account #{lunchflow_account_id} not found for item #{@lunchflow_item.id}")
            next
          end

          # Skip if already linked (race condition protection)
          if lunchflow_account.account_provider.present?
            Rails.logger.info("LunchFlow account #{lunchflow_account_id} already linked, skipping")
            next
          end

          selected_subtype = account_subtypes[lunchflow_account_id]

          # Default subtype for CreditCard since it only has one option
          selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

          # Create account with user-selected type and subtype (raises on failure)
          # Skip initial sync - provider sync will handle balance creation with correct currency
          account = Account.create_and_sync(
            {
              family: Current.family,
              name: lunchflow_account.name,
              balance: lunchflow_account.current_balance || 0,
              currency: lunchflow_account.currency || "USD",
              accountable_type: selected_type,
              accountable_attributes: selected_subtype.present? ? { subtype: selected_subtype } : {}
            },
            skip_initial_sync: true
          )

          # Link account to lunchflow_account via account_providers join table (raises on failure)
          AccountProvider.create!(
            account: account,
            provider: lunchflow_account
          )

          created_accounts << account
        end
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error("LunchFlow account setup failed: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      flash[:alert] = t(".creation_failed", error: e.message)
      redirect_to accounts_path, status: :see_other
      return
    rescue StandardError => e
      Rails.logger.error("LunchFlow account setup failed unexpectedly: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      flash[:alert] = t(".creation_failed", error: "An unexpected error occurred")
      redirect_to accounts_path, status: :see_other
      return
    end

    # Trigger a sync to process transactions
    @lunchflow_item.sync_later if created_accounts.any?

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
      @lunchflow_items = Current.family.lunchflow_items.ordered

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
          ActionView::RecordIdentifier.dom_id(@lunchflow_item),
          partial: "lunchflow_items/lunchflow_item",
          locals: { lunchflow_item: @lunchflow_item }
        )
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    # Fetch Lunchflow accounts from the API and store them locally
    # Returns nil on success, or an error message string on failure
    def fetch_lunchflow_accounts_from_api
      # Skip if we already have accounts cached
      return nil unless @lunchflow_item.lunchflow_accounts.empty?

      # Validate API key is configured
      unless @lunchflow_item.credentials_configured?
        return t("lunchflow_items.setup_accounts.no_api_key")
      end

      # Use the specific lunchflow_item's provider (scoped to this family's item)
      lunchflow_provider = @lunchflow_item.lunchflow_provider
      unless lunchflow_provider.present?
        return t("lunchflow_items.setup_accounts.no_api_key")
      end

      begin
        accounts_data = lunchflow_provider.get_accounts
        available_accounts = accounts_data[:accounts] || []

        if available_accounts.empty?
          Rails.logger.info("LunchFlow API returned no accounts for item #{@lunchflow_item.id}")
          return nil
        end

        available_accounts.each do |account_data|
          next if account_data[:name].blank?

          lunchflow_account = @lunchflow_item.lunchflow_accounts.find_or_initialize_by(
            account_id: account_data[:id].to_s
          )
          lunchflow_account.upsert_lunchflow_snapshot!(account_data)
          lunchflow_account.save!
        end

        nil # Success
      rescue Provider::Lunchflow::LunchflowError => e
        Rails.logger.error("LunchFlow API error: #{e.message}")
        t("lunchflow_items.setup_accounts.api_error", message: e.message)
      rescue StandardError => e
        Rails.logger.error("Unexpected error fetching LunchFlow accounts: #{e.class}: #{e.message}")
        t("lunchflow_items.setup_accounts.api_error", message: e.message)
      end
    end
    def set_lunchflow_item
      @lunchflow_item = Current.family.lunchflow_items.find(params[:id])
    end

    def lunchflow_params
      params.require(:lunchflow_item).permit(:name, :sync_start_date, :api_key, :base_url)
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
