class SophtronItemsController < ApplicationController
  before_action :set_sophtron_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @sophtron_items = Current.family.sophtron_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  # Preload Sophtron accounts in background (async, non-blocking)
  def preload_accounts
    begin
      # Check if family has credentials
      unless Current.family.has_sophtron_credentials?
        render json: { success: false, error: "no_credentials", has_accounts: false }
        return
      end

      cache_key = "sophtron_accounts_#{Current.family.id}"

      # Check if already cached
      cached_accounts = Rails.cache.read(cache_key)

      if cached_accounts.present?
        render json: { success: true, has_accounts: cached_accounts.any?, cached: true }
        return
      end

      # Fetch from API
      sophtron_provider = Provider::SophtronAdapter.build_provider(family: Current.family)

      unless sophtron_provider.present?
        render json: { success: false, error: "no_access_key", has_accounts: false }
        return
      end

      response = sophtron_provider.get_accounts
      available_accounts = response.data[:accounts] || []

      # Cache the accounts for 5 minutes
      Rails.cache.write(cache_key, available_accounts, expires_in: 5.minutes)

      render json: { success: true, has_accounts: available_accounts.any?, cached: false }
    rescue Provider::Error => e
      Rails.logger.error("Sophtron preload error: #{e.message}")
      # API error (bad key, network issue, etc) - keep button visible, show error when clicked
      render json: { success: false, error: "api_error", error_message: e.message, has_accounts: nil }
    rescue StandardError => e
      Rails.logger.error("Unexpected error preloading Sophtron accounts: #{e.class}: #{e.message}")
      # Unexpected error - keep button visible, show error when clicked
      render json: { success: false, error: "unexpected_error", error_message: e.message, has_accounts: nil }
    end
  end

  # Fetch available accounts from Sophtron API and show selection UI
  def select_accounts
    begin
      # Check if family has Sophtron credentials configured
      unless Current.family.has_sophtron_credentials?
        if turbo_frame_request?
          # Render setup modal for turbo frame requests
          render partial: "sophtron_items/setup_required", layout: false
        else
          # Redirect for regular requests
          redirect_to settings_providers_path,
                     alert: t(".no_credentials_configured",
                            default: "Please configure your Sophtron API key first in Provider Settings.")
        end
        return
      end

      cache_key = "sophtron_accounts_#{Current.family.id}"

      # Try to get cached accounts first
      @available_accounts = Rails.cache.read(cache_key)

      # If not cached, fetch from API
      if @available_accounts.nil?
        sophtron_provider = Provider::SophtronAdapter.build_provider(family: Current.family)

        unless sophtron_provider.present?
          redirect_to settings_providers_path, alert: t(".no_access_key",
                                                        default: "Sophtron access key not found. Please configure it in Provider Settings.")
          return
        end

        response = sophtron_provider.get_accounts
        @available_accounts = response.data[:accounts] || []

        # Cache the accounts for 5 minutes
        Rails.cache.write(cache_key, @available_accounts, expires_in: 5.minutes)
      end

      # Filter out already linked accounts
      sophtron_item = Current.family.sophtron_items.first
      if sophtron_item
        linked_account_ids = sophtron_item.sophtron_accounts.joins(:account_provider).pluck(:account_id)
        @available_accounts = @available_accounts.reject { |acc| linked_account_ids.include?(acc[:id].to_s) }
      end

      @accountable_type = params[:accountable_type] || "Depository"
      @return_to = safe_return_to_path

      if @available_accounts.empty?
        redirect_to new_account_path, alert: t(".no_accounts_found")
        return
      end

      render layout: false
    rescue Provider::Error => e
      Rails.logger.error("Sophtron API error in select_accounts: #{e.message}")
      @error_message = t(".api_error", message: e.message)
      @return_path = safe_return_to_path
      render partial: "sophtron_items/api_error",
             locals: { error_message: @error_message, return_path: @return_path },
             layout: false
    rescue StandardError => e
      Rails.logger.error("Unexpected error in select_accounts: #{e.class}: #{e.message}")
      @error_message = t(".unexpected_error", message: e.message)
      @return_path = safe_return_to_path
      render partial: "sophtron_items/api_error",
             locals: { error_message: @error_message, return_path: @return_path },
             layout: false
    end
  end

  # Create accounts from selected Sophtron accounts
  def link_accounts
    selected_account_ids = params[:account_ids] || []
    accountable_type = params[:accountable_type] || "Depository"
    return_to = safe_return_to_path

    if selected_account_ids.empty?
      redirect_to new_account_path, alert: t(".no_accounts_selected")
      return
    end

    # Create or find sophtron_item for this family
    sophtron_item = Current.family.sophtron_items.first_or_create!(
      name: "Sophtron Connection"
    )

    # Fetch account details from API
    sophtron_provider = Provider::SophtronAdapter.build_provider(family: Current.family)
    unless sophtron_provider.present?
      redirect_to new_account_path, alert: t(".no_access_key")
      return
    end

    response = sophtron_provider.get_accounts

    created_accounts = []
    already_linked_accounts = []
    invalid_accounts = []

    selected_account_ids.each do |account_id|
      # Find the account data from API response
      account_data = response.data[:accounts].find { |acc| acc[:id].to_s == account_id.to_s }
      next unless account_data

      # Validate account name is not blank (required by Account model)
      if account_data[:account_name].blank?
        invalid_accounts << account_id
        Rails.logger.warn "SophtronItemsController - Skipping account #{account_id} with blank name"
        next
      end

      # Create or find sophtron_account
      sophtron_account = sophtron_item.sophtron_accounts.find_or_initialize_by(
        account_id: account_id.to_s
      )
      sophtron_account.upsert_sophtron_snapshot!(account_data)
      sophtron_account.save!
      # Check if this sophtron_account is already linked
      if sophtron_account.account_provider.present?
        already_linked_accounts << account_data[:account_name]
        next
      end

      # Create the internal Account with proper balance initialization
      account = Account.create_and_sync(
        {
          family: Current.family,
          name: account_data[:account_name],
          balance: 0, # Initial balance will be set during sync
          currency: account_data[:currency] || "USD",
          accountable_type: accountable_type,
          accountable_attributes: {}
        },
        skip_initial_sync: true
      )
      # Link account to sophtron_account via account_providers join table
      AccountProvider.create!(
        account: account,
        provider: sophtron_account
      )

      created_accounts << account
    end

    # Trigger sync to fetch transactions if any accounts were created
    sophtron_item.sync_later if created_accounts.any?

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
  rescue Provider::Error => e
    redirect_to new_account_path, alert: t(".api_error", message: e.message)
  end

  # Fetch available Sophtron accounts to link with an existing account
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

    # Check if family has Sophtron credentials configured
    unless Current.family.has_sophtron_credentials?
      if turbo_frame_request?
        # Render setup modal for turbo frame requests
        render partial: "sophtron_items/setup_required", layout: false
      else
        # Redirect for regular requests
        redirect_to settings_providers_path,
                   alert: t(".no_credentials_configured",
                          default: "Please configure your Sophtron API key first in Provider Settings.")
      end
      return
    end

    begin
      cache_key = "sophtron_accounts_#{Current.family.id}"

      # Try to get cached accounts first
      @available_accounts = Rails.cache.read(cache_key)

      # If not cached, fetch from API
      if @available_accounts.nil?
        sophtron_provider = Provider::SophtronAdapter.build_provider(family: Current.family)

        unless sophtron_provider.present?
          redirect_to settings_providers_path, alert: t(".no_access_key",
                                                        default: "Sophtron User ID and Access key not found. Please configure it in Provider Settings.")
          return
        end

        response = sophtron_provider.get_accounts
        @available_accounts = response.data[:accounts] || []

        # Cache the accounts for 5 minutes
        Rails.cache.write(cache_key, @available_accounts, expires_in: 5.minutes)
      end

      if @available_accounts.empty?
        redirect_to accounts_path, alert: t(".no_accounts_found")
        return
      end

      # Filter out already linked accounts
      sophtron_item = Current.family.sophtron_items.first
      if sophtron_item
        linked_account_ids = sophtron_item.sophtron_accounts.joins(:account_provider).pluck(:account_id)
        @available_accounts = @available_accounts.reject { |acc| linked_account_ids.include?(acc[:id].to_s) }
      end

      if @available_accounts.empty?
        redirect_to accounts_path, alert: t(".all_accounts_already_linked")
        return
      end

      @return_to = safe_return_to_path

      render layout: false
    rescue Provider::Error => e
      Rails.logger.error("Sophtron API error in select_existing_account: #{e.message}")
      @error_message = t(".api_error", message: e.message)
      render partial: "sophtron_items/api_error",
             locals: { error_message: @error_message, return_path: accounts_path },
             layout: false
    rescue StandardError => e
      Rails.logger.error("Unexpected error in select_existing_account: #{e.class}: #{e.message}")
      @error_message = t(".unexpected_error")
      render partial: "sophtron_items/api_error",
             locals: { error_message: @error_message, return_path: accounts_path },
             layout: false
    end
  end

  # Link a selected Sophtron account to an existing account
  def link_existing_account
    account_id = params[:account_id]
    sophtron_account_id = params[:sophtron_account_id]
    return_to = safe_return_to_path

    unless account_id.present? && sophtron_account_id.present?
      redirect_to accounts_path, alert: t(".missing_parameters")
      return
    end

    @account = Current.family.accounts.find(account_id)

    # Check if account is already linked
    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    # Create or find sophtron_item for this family
    sophtron_item = Current.family.sophtron_items.first_or_create!(
      name: "Sophtron Connection"
    )

    # Fetch account details from API
    sophtron_provider = Provider::SophtronAdapter.build_provider(family: Current.family)
    unless sophtron_provider.present?
      redirect_to accounts_path, alert: t(".no_access_key")
      return
    end

    response = sophtron_provider.get_accounts

    # Find the selected Sophtron account data
    account_data = response.data[:accounts].find { |acc| acc[:id].to_s == sophtron_account_id.to_s }
    unless account_data
      redirect_to accounts_path, alert: t(".sophtron_account_not_found")
      return
    end

    # Validate account name is not blank (required by Account model)
    if account_data[:account_name].blank?
      redirect_to accounts_path, alert: t(".invalid_account_name")
      return
    end

    # Create or find sophtron_account
    sophtron_account = sophtron_item.sophtron_accounts.find_or_initialize_by(
      account_id: sophtron_account_id.to_s
    )
    sophtron_account.upsert_sophtron_snapshot!(account_data)
    sophtron_account.save!

    # Check if this sophtron_account is already linked to another account
    if sophtron_account.account_provider.present?
      redirect_to accounts_path, alert: t(".sophtron_account_already_linked")
      return
    end

    # Link account to sophtron_account via account_providers join table
    AccountProvider.create!(
      account: @account,
      provider: sophtron_account
    )

    # Trigger sync to fetch transactions
    sophtron_item.sync_later
    redirect_to return_to || accounts_path,
                notice: t(".success", account_name: @account.name)
  rescue Provider::Error => e
    redirect_to accounts_path, alert: t(".api_error", message: e.message)
  end

  def new
    @sophtron_item = Current.family.sophtron_items.build
  end

  def create
    @sophtron_item = Current.family.sophtron_items.build(sophtron_params)
    @sophtron_item.name ||= "Sophtron Connection"
    if @sophtron_item.save
      # Trigger initial sync to fetch accounts
      @sophtron_item.sync_later
      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @sophtron_items = Current.family.sophtron_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "sophtron-providers-panel",
            partial: "settings/providers/sophtron_panel",
            locals: { sophtron_items: @sophtron_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @sophtron_item.errors.full_messages.join(", ")
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "sophtron-providers-panel",
          partial: "settings/providers/sophtron_panel",
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
    if @sophtron_item.update(sophtron_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @sophtron_items = Current.family.sophtron_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "sophtron-providers-panel",
            partial: "settings/providers/sophtron_panel",
            locals: { sophtron_items: @sophtron_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @sophtron_item.errors.full_messages.join(", ")
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "sophtron-providers-panel",
          partial: "settings/providers/sophtron_panel",
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
      @sophtron_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("Sophtron unlink during destroy failed: #{e.class} - #{e.message}")
    end
    @sophtron_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    unless @sophtron_item.syncing?
      @sophtron_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Show unlinked Sophtron accounts for setup (similar to SimpleFIN setup_accounts)
  def setup_accounts
    # First, ensure we have the latest accounts from the API
    @api_error = fetch_sophtron_accounts_from_api

    # Get Sophtron accounts that are not linked (no AccountProvider)
    @sophtron_accounts = @sophtron_item.sophtron_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    # Get supported account types from the adapter
    supported_types = Provider::SophtronAdapter.supported_account_types

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
    valid_types = Provider::SophtronAdapter.supported_account_types

    created_accounts = []
    skipped_count = 0

    begin
      ActiveRecord::Base.transaction do
        account_types.each do |sophtron_account_id, selected_type|
          # Skip accounts marked as "skip"
          if selected_type == "skip" || selected_type.blank?
            skipped_count += 1
            next
          end

          # Validate account type is supported
          unless valid_types.include?(selected_type)
            Rails.logger.warn("Invalid account type '#{selected_type}' submitted for Sophtron account #{sophtron_account_id}")
            next
          end

          # Find account - scoped to this item to prevent cross-item manipulation
          sophtron_account = @sophtron_item.sophtron_accounts.find_by(id: sophtron_account_id)
          unless sophtron_account
            Rails.logger.warn("Sophtron account #{sophtron_account_id} not found for item #{@sophtron_item.id}")
            next
          end

          # Skip if already linked (race condition protection)
          if sophtron_account.account_provider.present?
            Rails.logger.info("Sophtron account #{sophtron_account_id} already linked, skipping")
            next
          end

          selected_subtype = account_subtypes[sophtron_account_id]

          # Default subtype for CreditCard since it only has one option
          selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

          # Create account with user-selected type and subtype (raises on failure)
          account = Account.create_and_sync(
            {
            family: Current.family,
            name: sophtron_account.name,
            balance: sophtron_account.balance || 0,
            currency: sophtron_account.currency || "USD",
            accountable_type: selected_type,
            accountable_attributes: selected_subtype.present? ? { subtype: selected_subtype } : {}
            },
            skip_initial_sync: true
          )

          # Link account to sophtron_account via account_providers join table (raises on failure)
          AccountProvider.create!(
            account: account,
            provider: sophtron_account
          )

          created_accounts << account
        end
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error("Sophtron account setup failed: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      flash[:alert] = t(".creation_failed", error: e.message)
      redirect_to accounts_path, status: :see_other
      return
    rescue StandardError => e
      Rails.logger.error("Sophtron account setup failed unexpectedly: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      flash[:alert] = t(".creation_failed", error: "An unexpected error occurred")
      redirect_to accounts_path, status: :see_other
      return
    end

    # Trigger a sync to process transactions
    @sophtron_item.sync_later if created_accounts.any?

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
      @sophtron_items = Current.family.sophtron_items.ordered
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
          ActionView::RecordIdentifier.dom_id(@sophtron_item),
          partial: "sophtron_items/sophtron_item",
          locals: { sophtron_item: @sophtron_item }
        )
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    # Fetch Sophtron accounts from the API and store them locally
    # Returns nil on success, or an error message string on failure
    def fetch_sophtron_accounts_from_api
      # Skip if we already have accounts cached
      existing_count = @sophtron_item.sophtron_accounts.count
      return nil unless @sophtron_item.sophtron_accounts.empty?

      # Validate Access key is configured
      unless @sophtron_item.credentials_configured?
        return t("sophtron_items.setup_accounts.no_access_key")
      end

      # Use the specific sophtron_item's provider (scoped to this family's item)
      sophtron_provider = @sophtron_item.sophtron_provider
      unless sophtron_provider.present?
        return t("sophtron_items.setup_accounts.no_access_key")
      end

      begin
        response = sophtron_provider.get_accounts
        available_accounts = response.data[:accounts] || []

        if available_accounts.empty?
          return nil
        end

        available_accounts.each_with_index do |account_data, index|
          next if account_data[:account_name].blank?

          sophtron_account = @sophtron_item.sophtron_accounts.find_or_initialize_by(
            account_id: account_data[:account_id].to_s
          )
          sophtron_account.upsert_sophtron_snapshot!(account_data)
          sophtron_account.save!
        end

        nil # Success
      rescue Provider::Error => e
        Rails.logger.error("Sophtron API error: #{e.message}")
        t("sophtron_items.setup_accounts.api_error", message: e.message)
      rescue StandardError => e
        Rails.logger.error("Unexpected error fetching Sophtron accounts: #{e.class}: #{e.message}")
        Rails.logger.error(e.backtrace.first(10).join("\n"))
        t("sophtron_items.setup_accounts.api_error", message: e.message)
      end
    end

    def set_sophtron_item
      @sophtron_item = Current.family.sophtron_items.find(params[:id])
    end

    def sophtron_params
      params.require(:sophtron_item).permit(:name, :user_id, :access_key, :base_url, :sync_start_date)
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
