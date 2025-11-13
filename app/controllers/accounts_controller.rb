class AccountsController < ApplicationController
  before_action :set_account, only: %i[sync sparkline toggle_active show destroy unlink confirm_unlink select_provider]
  include Periodable

  def index
    @manual_accounts = family.accounts.manual.alphabetically
    @plaid_items = family.plaid_items.ordered
    @simplefin_items = family.simplefin_items.ordered
    @lunchflow_items = family.lunchflow_items.ordered

    render layout: "settings"
  end

  def new
    @show_lunchflow_link = family.can_connect_lunchflow?
  end

  def sync_all
    family.sync_later
    redirect_to accounts_path, notice: "Syncing accounts..."
  end

  def show
    @chart_view = params[:chart_view] || "balance"
    @tab = params[:tab]
    @q = params.fetch(:q, {}).permit(:search)
    entries = @account.entries.search(@q).reverse_chronological

    @pagy, @entries = pagy(entries, limit: params[:per_page] || "10")

    @activity_feed_data = Account::ActivityFeedData.new(@account, @entries)
  end

  def sync
    unless @account.syncing?
      if @account.linked?
        # Sync all provider items for this account
        # Each provider item will trigger an account sync when complete
        @account.account_providers.each do |account_provider|
          item = account_provider.adapter&.item
          item&.sync_later if item && !item.syncing?
        end
      else
        # Manual accounts just need balance materialization
        @account.sync_later
      end
    end

    redirect_to account_path(@account)
  end

  def sparkline
    etag_key = @account.family.build_cache_key("#{@account.id}_sparkline", invalidate_on_data_updates: true)

    # Short-circuit with 304 Not Modified when the client already has the latest version.
    # We defer the expensive series computation until we know the content is stale.
    if stale?(etag: etag_key, last_modified: @account.family.latest_sync_completed_at)
      @sparkline_series = @account.sparkline_series
      render layout: false
    end
  end

  def toggle_active
    if @account.active?
      @account.disable!
    elsif @account.disabled?
      @account.enable!
    end
    redirect_to accounts_path
  end

  def destroy
    if @account.linked?
      redirect_to account_path(@account), alert: "Cannot delete a linked account"
    else
      @account.destroy_later
      redirect_to accounts_path, notice: "Account scheduled for deletion"
    end
  end

  def confirm_unlink
    unless @account.linked?
      redirect_to account_path(@account), alert: "Account is not linked to a provider"
    end
  end

  def unlink
    if @account.linked?
      # Remove new system links (account_providers join table)
      @account.account_providers.destroy_all

      # Remove legacy system links (foreign keys)
      @account.update!(plaid_account_id: nil, simplefin_account_id: nil)

      redirect_to accounts_path, notice: "Account unlinked successfully. It is now a manual account."
    else
      redirect_to account_path(@account), alert: "Account is not linked to a provider"
    end
  end

  def select_provider
    if @account.linked?
      redirect_to account_path(@account), alert: "Account is already linked to a provider"
      return
    end

    @available_providers = []

    # Check SimpleFIN
    if family.can_connect_simplefin?
      @available_providers << {
        name: "SimpleFIN",
        key: "simplefin",
        description: "Connect to your bank via SimpleFIN",
        path: select_existing_account_simplefin_items_path(account_id: @account.id)
      }
    end

    # Check Plaid US
    if family.can_connect_plaid_us?
      @available_providers << {
        name: "Plaid",
        key: "plaid_us",
        description: "Connect to your US bank via Plaid",
        path: select_existing_account_plaid_items_path(account_id: @account.id, region: "us")
      }
    end

    # Check Plaid EU
    if family.can_connect_plaid_eu?
      @available_providers << {
        name: "Plaid (EU)",
        key: "plaid_eu",
        description: "Connect to your EU bank via Plaid",
        path: select_existing_account_plaid_items_path(account_id: @account.id, region: "eu")
      }
    end

    # Check Lunch Flow
    if family.can_connect_lunchflow?
      @available_providers << {
        name: "Lunch Flow",
        key: "lunchflow",
        description: "Connect to your bank via Lunch Flow",
        path: select_existing_account_lunchflow_items_path(account_id: @account.id)
      }
    end

    if @available_providers.empty?
      redirect_to account_path(@account), alert: "No providers are currently configured"
    end
  end

  private
    def family
      Current.family
    end

    def set_account
      @account = family.accounts.find(params[:id])
    end
end
