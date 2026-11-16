class LunchflowItemsController < ApplicationController
  include SafeReturnPath

  before_action :set_lunchflow_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :new, :create, :preload_accounts, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @lunchflow_items = Current.family.lunchflow_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def preload_accounts
    render json: account_flow.preload_payload
  end

  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    result = account_flow.select_accounts_result(accountable_type: @accountable_type)

    return handle_selection_result(result, empty_path: new_account_path, api_return_path: @return_to) unless result.success?

    @lunchflow_item = result.item
    @available_accounts = result.available_accounts

    render layout: false
  end

  def link_accounts
    result = account_flow.link_new_accounts_result(
      account_ids: params[:account_ids] || [],
      accountable_type: params[:accountable_type] || "Depository"
    )

    redirect_with_navigation(result, return_to: safe_return_to_path)
  end

  def select_existing_account
    return redirect_to accounts_path, alert: t(".no_account_specified") if params[:account_id].blank?

    @account = Current.family.accounts.find_by(id: params[:account_id])
    return redirect_to accounts_path, alert: t(".no_account_specified") unless @account

    result = account_flow.select_existing_account_result(account: @account)

    return handle_selection_result(result, empty_path: accounts_path, api_return_path: accounts_path) unless result.success?

    @lunchflow_item = result.item
    @available_accounts = result.available_accounts
    @return_to = safe_return_to_path

    render layout: false
  end

  def link_existing_account
    return redirect_to accounts_path, alert: t(".no_account_specified") if params[:account_id].blank?

    account = Current.family.accounts.find_by(id: params[:account_id])
    return redirect_to accounts_path, alert: t(".no_account_specified") unless account

    result = account_flow.link_existing_account_result(account: account, provider_account_id: params[:lunchflow_account_id])

    redirect_with_navigation(result, return_to: safe_return_to_path)
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

      redirect_to accounts_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("lunchflow", alert: @lunchflow_item.errors.full_messages.join(", "))
    end
  end

  def edit
  end

  def update
    permitted = lunchflow_params
    if @lunchflow_item.update(permitted)
      Rails.cache.delete(lunchflow_accounts_cache_key(@lunchflow_item)) if permitted.key?(:api_key) || permitted.key?(:base_url)
      render_provider_panel("lunchflow", notice: t(".success"), fallback_path: accounts_path)
    else
      render_provider_panel("lunchflow", alert: @lunchflow_item.errors.full_messages.join(", "))
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
    translate_subtypes = ->(type_key, accountable_class) {
      accountable_class::SUBTYPES.keys.map do |key|
        [ t(".subtypes.#{type_key}.#{key}", default: accountable_class.long_subtype_label_for(key)), key ]
      end
    }

    # Subtype options for each account type (only include supported types)
    all_subtype_options = {
      "Depository" => {
        label: t(".subtype_labels.depository"),
        options: translate_subtypes.call("depository", Depository)
      },
      "CreditCard" => {
        label: t(".subtype_labels.credit_card"),
        options: [],
        message: t(".subtype_messages.credit_card")
      },
      "Investment" => {
        label: t(".subtype_labels.investment"),
        options: translate_subtypes.call("investment", Investment)
      },
      "Loan" => {
        label: t(".subtype_labels.loan"),
        options: translate_subtypes.call("loan", Loan)
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
      flash[:alert] = t(".creation_failed", error: t(".unexpected_error"))
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
          .visible_manual_for(Current.user)
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
        # Admin-only action (require_admin!), so the card lists every account.
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@lunchflow_item),
          partial: "lunchflow_items/lunchflow_item",
          locals: { lunchflow_item: @lunchflow_item, visible_accounts: @lunchflow_item.accounts }
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

    def account_flow
      @account_flow ||= LunchflowItem::AccountFlow.new(family: Current.family, item_id: params[:lunchflow_item_id], item: @lunchflow_item)
    end

    def handle_selection_result(result, empty_path:, api_return_path:)
      case result.status
      when :empty, :account_already_linked
        redirect_to empty_path, alert: result.message
      when :no_api_token, :select_connection
        redirect_to settings_providers_path, alert: result.message
      when :setup_required
        if turbo_frame_request?
          render partial: "lunchflow_items/setup_required", layout: false
        else
          redirect_to settings_providers_path, alert: result.message
        end
      when :api_error, :unexpected_error
        render partial: "lunchflow_items/api_error", locals: { error_message: result.message, return_path: api_return_path }, layout: false
      else
        redirect_to settings_providers_path, alert: result.message
      end
    end

    def redirect_with_navigation(result, return_to:)
      path = {
        new_account: new_account_path,
        settings_providers: settings_providers_path,
        return_to_or_accounts: return_to || accounts_path
      }.fetch(result.target, accounts_path)

      redirect_to path, result.flash_type => result.message
    end

    def set_lunchflow_item
      @lunchflow_item = Current.family.lunchflow_items.find(params[:id])
    end

    def lunchflow_params
      params.require(:lunchflow_item).permit(:name, :sync_start_date, :api_key, :base_url)
    end

    # The accounts list is cached per connection, under the provider kit's key.
    def lunchflow_accounts_cache_key(lunchflow_item)
      "lunchflow_accounts_#{Current.family.id}_#{lunchflow_item.id}"
    end
end
