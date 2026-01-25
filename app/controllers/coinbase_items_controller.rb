class CoinbaseItemsController < ApplicationController
  before_action :set_coinbase_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @coinbase_items = Current.family.coinbase_items.ordered
  end

  def show
  end

  def new
    @coinbase_item = Current.family.coinbase_items.build
  end

  def edit
  end

  def create
    @coinbase_item = Current.family.coinbase_items.build(coinbase_item_params)
    @coinbase_item.name ||= t(".default_name")

    if @coinbase_item.save
      # Set default institution metadata
      @coinbase_item.set_coinbase_institution_defaults!

      # Trigger initial sync to fetch accounts
      @coinbase_item.sync_later

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @coinbase_items = Current.family.coinbase_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "coinbase-providers-panel",
            partial: "settings/providers/coinbase_panel",
            locals: { coinbase_items: @coinbase_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @coinbase_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "coinbase-providers-panel",
          partial: "settings/providers/coinbase_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @coinbase_item.update(coinbase_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @coinbase_items = Current.family.coinbase_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "coinbase-providers-panel",
            partial: "settings/providers/coinbase_panel",
            locals: { coinbase_items: @coinbase_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @coinbase_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "coinbase-providers-panel",
          partial: "settings/providers/coinbase_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @coinbase_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  def sync
    unless @coinbase_item.syncing?
      @coinbase_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Legacy provider linking flow (not used - Coinbase uses setup_accounts flow instead)
  # These exist for route compatibility but redirect to the providers page.

  def preload_accounts
    redirect_to settings_providers_path
  end

  def select_accounts
    redirect_to settings_providers_path
  end

  def link_accounts
    redirect_to settings_providers_path
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    # List all available Coinbase accounts for the family that can be linked
    @available_coinbase_accounts = Current.family.coinbase_items
      .includes(coinbase_accounts: [ :account, { account_provider: :account } ])
      .flat_map(&:coinbase_accounts)
      # Show accounts that are still linkable:
      # - Already linked via AccountProvider (can be relinked to different account)
      # - Or fully unlinked (no account_provider)
      .select { |ca| ca.account.present? || ca.account_provider.nil? }
      .sort_by { |ca| ca.updated_at || ca.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    # Scope lookup to family's coinbase accounts for security
    coinbase_account = Current.family.coinbase_items
      .joins(:coinbase_accounts)
      .where(coinbase_accounts: { id: params[:coinbase_account_id] })
      .first&.coinbase_accounts&.find_by(id: params[:coinbase_account_id])

    unless coinbase_account
      flash[:alert] = t(".errors.invalid_coinbase_account")
      if turbo_frame_request?
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to account_path(@account), alert: flash[:alert]
      end
      return
    end

    # Guard: only manual accounts can be linked (no existing provider links)
    if @account.account_providers.any? || @account.plaid_account_id.present? || @account.simplefin_account_id.present?
      flash[:alert] = t(".errors.only_manual")
      if turbo_frame_request?
        return render turbo_stream: Array(flash_notification_stream_items)
      else
        return redirect_to account_path(@account), alert: flash[:alert]
      end
    end

    # Relink behavior: detach any existing link and point provider link at the chosen account
    Account.transaction do
      coinbase_account.lock!

      # Upsert the AccountProvider mapping
      ap = AccountProvider.find_or_initialize_by(provider: coinbase_account)
      previous_account = ap.account
      ap.account_id = @account.id
      ap.save!

      # If the provider was previously linked to a different account in this family,
      # and that account is now orphaned, queue it for deletion
      if previous_account && previous_account.id != @account.id && previous_account.family_id == @account.family_id
        begin
          previous_account.reload
          if previous_account.account_providers.none?
            previous_account.destroy_later if previous_account.may_mark_for_deletion?
          end
        rescue => e
          Rails.logger.warn("Failed orphan cleanup for account ##{previous_account&.id}: #{e.class} - #{e.message}")
        end
      end
    end

    if turbo_frame_request?
      coinbase_account.reload
      item = coinbase_account.coinbase_item
      item.reload

      @manual_accounts = Account.uncached {
        Current.family.accounts
          .visible_manual
          .order(:name)
          .to_a
      }
      @coinbase_items = Current.family.coinbase_items.ordered.includes(:syncs)

      flash[:notice] = t(".success")
      @account.reload
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
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(item),
          partial: "coinbase_items/coinbase_item",
          locals: { coinbase_item: item }
        ),
        manual_accounts_stream,
        *Array(flash_notification_stream_items)
      ]
    else
      redirect_to accounts_path, notice: t(".success")
    end
  end

  def setup_accounts
    # Only show unlinked accounts
    @coinbase_accounts = @coinbase_item.coinbase_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)
  end

  def complete_account_setup
    selected_accounts = Array(params[:selected_accounts]).reject(&:blank?)

    created_accounts = []

    selected_accounts.each do |coinbase_account_id|
      # Find account - scoped to this item to prevent cross-item manipulation
      coinbase_account = @coinbase_item.coinbase_accounts.find_by(id: coinbase_account_id)
      unless coinbase_account
        Rails.logger.warn("Coinbase account #{coinbase_account_id} not found for item #{@coinbase_item.id}")
        next
      end

      # Lock row to prevent concurrent account creation (race condition protection)
      coinbase_account.with_lock do
        # Re-check after acquiring lock - another request may have created the account
        if coinbase_account.account.present?
          Rails.logger.info("Coinbase account #{coinbase_account_id} already linked, skipping")
          next
        end

        # Create account as Crypto exchange (all Coinbase accounts are crypto)
        account = Account.create_from_coinbase_account(coinbase_account)
        coinbase_account.ensure_account_provider!(account)
        created_accounts << account
      end

      # Reload to pick up the new account_provider association (outside lock)
      coinbase_account.reload

      # Process holdings immediately so user sees them right away
      # (sync_later is async and would delay holdings visibility)
      begin
        CoinbaseAccount::HoldingsProcessor.new(coinbase_account).process
      rescue => e
        Rails.logger.error("Failed to process holdings for #{coinbase_account.id}: #{e.message}")
      end
    end

    # Only clear pending if ALL accounts are now linked
    unlinked_remaining = @coinbase_item.coinbase_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .count
    @coinbase_item.update!(pending_account_setup: unlinked_remaining > 0)

    # Set appropriate flash message
    if created_accounts.any?
      flash[:notice] = t(".success", count: created_accounts.count)
    elsif selected_accounts.empty?
      flash[:notice] = t(".none_selected")
    else
      flash[:notice] = t(".no_accounts")
    end

    # Trigger a sync to process the newly linked accounts
    @coinbase_item.sync_later if created_accounts.any?

    if turbo_frame_request?
      @coinbase_items = Current.family.coinbase_items.ordered.includes(:syncs)

      render turbo_stream: [
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@coinbase_item),
          partial: "coinbase_items/coinbase_item",
          locals: { coinbase_item: @coinbase_item }
        )
      ] + Array(flash_notification_stream_items)
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    def set_coinbase_item
      @coinbase_item = Current.family.coinbase_items.find(params[:id])
    end

    def coinbase_item_params
      params.require(:coinbase_item).permit(
        :name,
        :sync_start_date,
        :api_key,
        :api_secret
      )
    end
end
