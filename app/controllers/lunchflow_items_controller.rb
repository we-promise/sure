class LunchflowItemsController < ApplicationController
  before_action :set_lunchflow_item, only: [ :show, :edit, :update, :destroy, :sync ]

  def index
    @lunchflow_items = Current.family.lunchflow_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  # Fetch available accounts from Lunchflow API and show selection UI
  def select_accounts
    begin
      cache_key = "lunchflow_accounts_#{Current.family.id}"

      # Try to get cached accounts first
      @available_accounts = Rails.cache.read(cache_key)

      # If not cached, fetch from API
      if @available_accounts.nil?
        lunchflow_provider = Provider::LunchflowAdapter.build_provider

        unless lunchflow_provider.present?
          redirect_to new_account_path, alert: t(".no_api_key")
          return
        end

        accounts_data = lunchflow_provider.get_accounts

        @available_accounts = accounts_data[:accounts] || []

        # Cache the accounts for 5 minutes
        Rails.cache.write(cache_key, @available_accounts, expires_in: 5.minutes)
      end

      @accountable_type = params[:accountable_type] || "Depository"
      @return_to = safe_return_to_path

      if @available_accounts.empty?
        redirect_to new_account_path, alert: t(".no_accounts_found")
        return
      end

      render layout: false
    rescue Provider::Lunchflow::LunchflowError => e
      redirect_to new_account_path, alert: t(".api_error", message: e.message)
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
      name: "Lunchflow Connection"
    )

    # Fetch account details from API
    lunchflow_provider = Provider::LunchflowAdapter.build_provider
    unless lunchflow_provider.present?
      redirect_to new_account_path, alert: t(".no_api_key")
      return
    end

    accounts_data = lunchflow_provider.get_accounts

    created_accounts = []
    already_linked_accounts = []

    selected_account_ids.each do |account_id|
      # Find the account data from API response
      account_data = accounts_data[:accounts].find { |acc| acc[:id].to_s == account_id.to_s }
      next unless account_data

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
      account = Account.create_and_sync(
        family: Current.family,
        name: account_data[:name],
        balance: 0, # Initial balance will be set during sync
        currency: account_data[:currency] || "USD",
        accountable_type: accountable_type,
        accountable_attributes: {}
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
    if created_accounts.any? && already_linked_accounts.any?
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

    begin
      cache_key = "lunchflow_accounts_#{Current.family.id}"

      # Try to get cached accounts first
      @available_accounts = Rails.cache.read(cache_key)

      # If not cached, fetch from API
      if @available_accounts.nil?
        lunchflow_provider = Provider::LunchflowAdapter.build_provider

        unless lunchflow_provider.present?
          redirect_to accounts_path, alert: t(".no_api_key")
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
      redirect_to accounts_path, alert: t(".api_error", message: e.message)
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
      name: "Lunchflow Connection"
    )

    # Fetch account details from API
    lunchflow_provider = Provider::LunchflowAdapter.build_provider
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
    @lunchflow_item.name = "Lunchflow Connection"

    if @lunchflow_item.save
      # Trigger initial sync to fetch accounts
      @lunchflow_item.sync_later

      redirect_to accounts_path, notice: t(".success")
    else
      @error_message = @lunchflow_item.errors.full_messages.join(", ")
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @lunchflow_item.update(lunchflow_params)
      redirect_to accounts_path, notice: t(".success")
    else
      @error_message = @lunchflow_item.errors.full_messages.join(", ")
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
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

  private
    def set_lunchflow_item
      @lunchflow_item = Current.family.lunchflow_items.find(params[:id])
    end

    def lunchflow_params
      params.require(:lunchflow_item).permit(:name, :sync_start_date)
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
