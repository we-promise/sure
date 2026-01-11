class TraderepublicItemsController < ApplicationController
  before_action :set_traderepublic_item, only: [ :edit, :update, :destroy, :sync, :verify_pin, :complete_login, :reauthenticate, :manual_sync ]

  def new
    @traderepublic_item = TraderepublicItem.new(family: Current.family)
    @accountable_type = params[:accountable_type]
    @return_to = params[:return_to]
  end

  def index
    @traderepublic_items = Current.family.traderepublic_items.includes(traderepublic_accounts: :account)
  end

  def create
    @traderepublic_item = TraderepublicItem.new(traderepublic_item_params.merge(family: Current.family))
    @accountable_type = params[:accountable_type]
    @return_to = params[:return_to]

    if @traderepublic_item.save
      begin
        @traderepublic_item.initiate_login!
        respond_to do |format|
          format.turbo_stream do
            render turbo_stream: turbo_stream.update(
              "modal",
              partial: "traderepublic_items/verify_pin",
              locals: { traderepublic_item: @traderepublic_item }
            )
          end
          format.html do
            redirect_to verify_pin_traderepublic_item_path(@traderepublic_item),
                        notice: t(".device_pin_sent", default: "Please check your phone for the verification PIN")
          end
        end
      rescue TraderepublicError => e
        @traderepublic_item.destroy if @traderepublic_item.persisted?
        respond_to do |format|
          format.turbo_stream do
            flash.now[:alert] = t(".login_failed", default: "Login failed: #{e.message}")
            render turbo_stream: turbo_stream.replace(
              "traderepublic-providers-panel",
              partial: "settings/providers/traderepublic_panel"
            )
          end
          format.html do
            redirect_to new_traderepublic_item_path, alert: t(".login_failed", default: "Login failed: #{e.message}")
          end
        end
      end
    else
      respond_to do |format|
        format.turbo_stream { render :new, status: :unprocessable_entity, layout: false }
        format.html { render :new, status: :unprocessable_entity }
      end
    end
  end

  # Manual sync: déclenche le flow PIN (initiate_login) puis popup PIN
  def manual_sync
    begin
      result = @traderepublic_item.initiate_login!
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update(
            "modal",
            partial: "traderepublic_items/verify_pin",
            locals: { traderepublic_item: @traderepublic_item, manual_sync: true }
          )
        end
        format.html do
          redirect_to verify_pin_traderepublic_item_path(@traderepublic_item, manual_sync: true),
                      notice: t(".device_pin_sent", default: "Please check your phone for the verification PIN")
        end
      end
    rescue TraderepublicError => e
      respond_to do |format|
        format.turbo_stream do
          flash.now[:alert] = t(".login_failed", default: "Manual sync failed: #{e.message}")
          render turbo_stream: turbo_stream.replace(
            "traderepublic-providers-panel",
            partial: "settings/providers/traderepublic_panel"
          )
        end
        format.html do
          redirect_to traderepublic_items_path, alert: t(".login_failed", default: "Manual sync failed: #{e.message}")
        end
      end
    end
  end

  def complete_login
      @traderepublic_item = Current.family.traderepublic_items.find(params[:id])
      device_pin = params[:device_pin]
      manual_sync = params[:manual_sync].to_s == 'true' || params[:manual_sync] == '1'

      if device_pin.blank?
        render json: { success: false, error: t(".pin_required", default: "PIN is required") }, status: :unprocessable_entity
        return
      end

    begin
      success = @traderepublic_item.complete_login!(device_pin)
      if success
        if manual_sync
          # Manual sync: fetch only new tranwsactions since last transaction for each account
          @traderepublic_item.traderepublic_accounts.each do |tr_account|
            last_date = tr_account.last_transaction_date
            provider = @traderepublic_item.traderepublic_provider
            # fetch new transactions (depuis la dernière date + 1 jour pour éviter doublons)
            since = last_date ? last_date + 1.day : nil
            new_snapshot = provider.get_timeline_transactions(since: since)
            tr_account.upsert_traderepublic_transactions_snapshot!(new_snapshot)
          end
          @traderepublic_item.process_accounts
          render json: {
            success: true,
            redirect_url: settings_providers_path
          }
        else
          # Trigger initial sync synchronously to get accounts
          # Skip token refresh since we just obtained fresh tokens
          Rails.logger.info "TradeRepublic: Starting initial sync for item #{@traderepublic_item.id}"
          sync_success = @traderepublic_item.import_latest_traderepublic_data(skip_token_refresh: true)
          if sync_success
            # Check if this is a re-authentication (has linked accounts) or new connection
            has_linked_accounts = @traderepublic_item.traderepublic_accounts.joins(:account_provider).exists?
            if has_linked_accounts
              # Re-authentication: process existing accounts and redirect to settings
              Rails.logger.info "TradeRepublic: Re-authentication detected, processing existing accounts"
              @traderepublic_item.process_accounts
              render json: {
                success: true,
                redirect_url: settings_providers_path
              }
            else
              # New connection: redirect to account selection
              render json: {
                success: true,
                redirect_url: select_accounts_traderepublic_items_path(
                  accountable_type: params[:accountable_type] || "Investment",
                  return_to: safe_return_to_path
                )
              }
            end
          else
            render json: { 
              success: false, 
              error: t(".sync_failed", default: "Connection successful but failed to fetch accounts. Please try syncing manually.") 
            }, status: :unprocessable_entity
          end
        end
      else
        render json: { success: false, error: t(".verification_failed", default: "PIN verification failed") }, status: :unprocessable_entity
      end
    rescue TraderepublicError => e
      Rails.logger.error "TradeRepublic PIN verification failed: \\#{e.message}"
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error "Unexpected error during PIN verification: \\#{e.class}: \\#{e.message}"
      render json: { success: false, error: t(".unexpected_error", default: "An unexpected error occurred") }, status: :internal_server_error
    end
  end

  # Show accounts selection after successful login
  def select_accounts
    @accountable_type = params[:accountable_type] || "Investment"
    @return_to = safe_return_to_path

    # Find the most recent traderepublic_item with valid session
    @traderepublic_item = Current.family.traderepublic_items
                                 .where.not(session_token: nil)
                                 .where(status: :good)
                                 .order(updated_at: :desc)
                                 .first

    unless @traderepublic_item
      redirect_to new_traderepublic_item_path, alert: t(".no_active_connection", default: "No active Trade Republic connection found")
      return
    end

    # Get available accounts
    @available_accounts = @traderepublic_item.traderepublic_accounts

    # Filter out already linked accounts
    linked_account_ids = @available_accounts.joins(:account_provider).pluck(:id)
    @available_accounts = @available_accounts.where.not(id: linked_account_ids)

    if @available_accounts.empty?
      if turbo_frame_request?
        @error_message = t(".no_accounts_available", default: "No Trade Republic accounts available for linking")
        @return_path = @return_to || new_account_path
        render partial: "traderepublic_items/api_error", locals: { error_message: @error_message, return_path: @return_path }, layout: false
      else
        redirect_to new_account_path, alert: t(".no_accounts_available", default: "No Trade Republic accounts available for linking")
      end
      return
    end

    render layout: turbo_frame_request? ? false : "application"
  rescue => e
    Rails.logger.error "Error in select_accounts: #{e.class}: #{e.message}"
    @error_message = t(".error_loading_accounts", default: "Failed to load accounts")
    @return_path = safe_return_to_path
    render partial: "traderepublic_items/api_error",
           locals: { error_message: @error_message, return_path: @return_path },
           layout: false
  end

  # Link selected accounts
  def link_accounts
    selected_account_ids = params[:account_ids] || []
    accountable_type = params[:accountable_type] || "Investment"
    return_to = safe_return_to_path

    if selected_account_ids.empty?
      redirect_to new_account_path, alert: t(".no_accounts_selected", default: "No accounts selected")
      return
    end

    traderepublic_item = Current.family.traderepublic_items
                                .where.not(session_token: nil)
                                .order(updated_at: :desc)
                                .first

    unless traderepublic_item
      redirect_to new_account_path, alert: t(".no_connection", default: "No Trade Republic connection found")
      return
    end

    created_accounts = []
    already_linked_accounts = []

    selected_account_ids.each do |account_id|
      traderepublic_account = traderepublic_item.traderepublic_accounts.find_by(id: account_id)
      next unless traderepublic_account

      # Check if already linked
      if traderepublic_account.account_provider.present?
        already_linked_accounts << traderepublic_account.name
        next
      end

      # Create the internal Account
      # For TradeRepublic (investment accounts), we don't create an opening balance
      # because we have complete transaction history and holdings
      account = Account.new(
        family: Current.family,
        name: traderepublic_account.name,
        balance: 0, # Will be calculated from holdings and transactions
        cash_balance: 0,
        currency: traderepublic_account.currency || "EUR",
        accountable_type: accountable_type,
        accountable_attributes: {}
      )
      
      Account.transaction do
        account.save!
        # Skip opening balance creation entirely for TradeRepublic accounts
      end
      
      account.sync_later

      # Link account via account_providers
      AccountProvider.create!(
        account: account,
        provider: traderepublic_account
      )

      created_accounts << account
    end

    if created_accounts.any?
      # Reload to pick up the newly created account_provider associations
      traderepublic_item.reload
      
      # Process transactions immediately for the newly linked accounts
      # This creates Entry records from the raw transaction data
      traderepublic_item.process_accounts
      
      # Trigger full sync in background to update balances and get latest data
      traderepublic_item.sync_later

      # Redirect to the newly created account if single account, or accounts list if multiple
      # Avoid redirecting back to /accounts/new
      redirect_path = if return_to == new_account_path || return_to.blank?
                        created_accounts.size == 1 ? account_path(created_accounts.first) : accounts_path
                      else
                        return_to
                      end

      redirect_to redirect_path, notice: t(".accounts_linked",
                                      count: created_accounts.count,
                                      default: "Successfully linked %{count} Trade Republic account(s)")
    elsif already_linked_accounts.any?
      redirect_to return_to, alert: t(".accounts_already_linked",
                                     default: "Selected accounts are already linked")
    else
      redirect_to new_account_path, alert: t(".no_valid_accounts", default: "No valid accounts to link")
    end
  end

  def edit
    render layout: false
  end

  def update
    if @traderepublic_item.update(traderepublic_item_params)
      redirect_to traderepublic_items_path, notice: t(".updated", default: "Trade Republic connection updated successfully")
    else
      render :edit, status: :unprocessable_entity, layout: false
    end
  end

  def destroy
    @traderepublic_item.destroy_later
    
    respond_to do |format|
      format.turbo_stream do
        flash.now[:notice] = t(".scheduled_for_deletion", default: "Trade Republic connection scheduled for deletion")
        render turbo_stream: [
          turbo_stream.remove("traderepublic-item-#{@traderepublic_item.id}"),
          turbo_stream.update("flash", partial: "shared/flash")
        ]
      end
      format.html do
        redirect_to traderepublic_items_path, notice: t(".scheduled_for_deletion", default: "Trade Republic connection scheduled for deletion")
      end
    end
  end

  def sync
    @traderepublic_item.sync_later
    
    respond_to do |format|
      format.turbo_stream do
        flash.now[:notice] = t(".sync_started", default: "Sync started")
        render turbo_stream: turbo_stream.replace(
          "traderepublic-providers-panel",
          partial: "settings/providers/traderepublic_panel"
        )
      end
      format.html do
        redirect_to traderepublic_items_path, notice: t(".sync_started", default: "Sync started")
      end
    end
  end

  def reauthenticate
    Rails.logger.info "TradeRepublic reauthenticate action called"
    Rails.logger.info "Request format: #{request.format}"
    Rails.logger.info "Turbo frame: #{request.headers['Turbo-Frame']}"
    
    begin
      result = @traderepublic_item.initiate_login!
      Rails.logger.info "Login initiated successfully"

      respond_to do |format|
        format.turbo_stream do
          Rails.logger.info "Rendering turbo_stream response"
          render turbo_stream: turbo_stream.update(
            "modal",
            partial: "traderepublic_items/verify_pin",
            locals: { traderepublic_item: @traderepublic_item }
          )
        end
        format.html do
          redirect_to verify_pin_traderepublic_item_path(@traderepublic_item),
                      notice: t(".device_pin_sent", default: "Please check your phone for the verification PIN")
        end
      end
    rescue TraderepublicError => e
      Rails.logger.error "TradeRepublic re-authentication initiation failed: #{e.message}"
      
      respond_to do |format|
        format.turbo_stream do
          flash.now[:alert] = t(".login_failed", default: "Re-authentication failed: #{e.message}")
          render turbo_stream: turbo_stream.replace(
            "traderepublic-providers-panel",
            partial: "settings/providers/traderepublic_panel"
          )
        end
        format.html do
          redirect_to traderepublic_items_path, alert: t(".login_failed", default: "Re-authentication failed: #{e.message}")
        end
      end
    end
  end

  # For existing account linking (when adding provider to existing account)
  def select_existing_account
    begin
      @account = Current.family.accounts.find(params[:account_id])
    rescue ActiveRecord::RecordNotFound
      redirect_to new_account_path, alert: t(".account_not_found", default: "Account not found")
      return
    end
    @accountable_type = @account.accountable_type

    # Get the most recent traderepublic_item with valid session
    @traderepublic_item = Current.family.traderepublic_items
                                 .where.not(session_token: nil)
                                 .where(status: :good)
                                 .order(updated_at: :desc)
                                 .first

    unless @traderepublic_item
      redirect_to new_traderepublic_item_path, alert: t(".no_active_connection")
      return
    end

    # Get available accounts (unlinked only)
    @available_accounts = @traderepublic_item.traderepublic_accounts
                                            .where.not(id: AccountProvider.where(provider_type: "TraderepublicAccount").select(:provider_id))

    render layout: false
  end

  # Link existing account
  def link_existing_account
    begin
      account = Current.family.accounts.find(params[:account_id])
    rescue ActiveRecord::RecordNotFound
      redirect_to new_account_path, alert: t(".account_not_found", default: "Account not found")
      return
    end
    traderepublic_account_id = params[:traderepublic_account_id]

    if traderepublic_account_id.blank?
      redirect_to account_path(account), alert: t(".no_account_selected")
      return
    end

    begin
      traderepublic_account = Current.family.traderepublic_accounts.find(traderepublic_account_id)
    rescue ActiveRecord::RecordNotFound
      redirect_to new_account_path, alert: t(".traderepublic_account_not_found", default: "Trade Republic account not found")
      return
    end

    # Check if already linked
    if traderepublic_account.account_provider.present?
      redirect_to account_path(account), alert: t(".already_linked")
      return
    end

    # Create the link
    AccountProvider.create!(
      account: account,
      provider: traderepublic_account
    )

    # Trigger sync
    traderepublic_account.traderepublic_item.sync_later

    redirect_to account_path(account), notice: t(".linked_successfully", default: "Trade Republic account linked successfully")
  end

  private

  def set_traderepublic_item
    @traderepublic_item = Current.family.traderepublic_items.find(params[:id])
  end

  def traderepublic_item_params
    params.fetch(:traderepublic_item, {}).permit(:name, :phone_number, :pin)
  end

  def safe_return_to_path
    return_to_raw = params[:return_to].to_s
    return new_account_path if return_to_raw.blank?

    decoded = CGI.unescape(return_to_raw)
    begin
      uri = URI.parse(decoded)
    rescue URI::InvalidURIError
      return new_account_path
    end

    # Only allow local paths: no scheme, no host, starts with a single leading slash (not protocol-relative //)
    path = uri.path || decoded
    if uri.scheme.nil? && uri.host.nil? && path.start_with?("/") && !path.start_with?("//")
      # Rebuild path with query and fragment if present
      built = path
      built += "?#{uri.query}" if uri.query.present?
      built += "##{uri.fragment}" if uri.fragment.present?
      return built
    end

    new_account_path
  end
end
