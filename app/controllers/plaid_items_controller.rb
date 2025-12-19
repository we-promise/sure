class PlaidItemsController < ApplicationController
  before_action :set_plaid_item, only: %i[edit destroy sync]

  def new
    region = params[:region] == "eu" ? :eu : :us
    webhooks_url = region == :eu ? plaid_eu_webhooks_url : plaid_us_webhooks_url

    @link_token = Current.family.get_link_token(
      webhooks_url: webhooks_url,
      redirect_url: accounts_url,
      accountable_type: params[:accountable_type] || "Depository",
      region: region
    )
  end

  def edit
    webhooks_url = @plaid_item.plaid_region == "eu" ? plaid_eu_webhooks_url : plaid_us_webhooks_url

    @link_token = @plaid_item.get_update_link_token(
      webhooks_url: webhooks_url,
      redirect_url: accounts_url,
    )
  end

  def create
    Current.family.create_plaid_item!(
      public_token: plaid_item_params[:public_token],
      item_name: item_name,
      region: plaid_item_params[:region]
    )

    redirect_to accounts_path, notice: t(".success")
  end

  def destroy
    @plaid_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    unless @plaid_item.syncing?
      @plaid_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @region = params[:region] || "us"

    # Get all Plaid accounts from this family's Plaid items for the specified region
    # that are not yet linked to any account
    @available_plaid_accounts = Current.family.plaid_items
      .where(plaid_region: @region)
      .includes(:plaid_accounts)
      .flat_map(&:plaid_accounts)
      .select { |pa| pa.account_provider.nil? && pa.account.nil? } # Not linked via new or legacy system

    if @available_plaid_accounts.empty?
      redirect_to account_path(@account), alert: "No available Plaid accounts to link. Please connect a new Plaid account first."
    end
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    plaid_account = PlaidAccount.find(params[:plaid_account_id])

    # Verify the Plaid account belongs to this family's Plaid items
    unless Current.family.plaid_items.include?(plaid_account.plaid_item)
      redirect_to account_path(@account), alert: "Invalid Plaid account selected"
      return
    end

    # Verify the Plaid account is not already linked
    if plaid_account.account_provider.present? || plaid_account.account.present?
      redirect_to account_path(@account), alert: "This Plaid account is already linked"
      return
    end

    # Create the link via AccountProvider
    AccountProvider.create!(
      account: @account,
      provider: plaid_account
    )

    redirect_to accounts_path, notice: "Account successfully linked to Plaid"
  end

  private
    def set_plaid_item
      @plaid_item = Current.family.plaid_items.find(params[:id])
    end

    def plaid_item_params
      params.require(:plaid_item).permit(:public_token, :region, metadata: {})
    end

    def item_name
      plaid_item_params.dig(:metadata, :institution, :name)
    end

    def plaid_us_webhooks_url
      return webhooks_plaid_url if Rails.env.production?

      ENV.fetch("DEV_WEBHOOKS_URL", root_url.chomp("/")) + "/webhooks/plaid"
    end

    def plaid_eu_webhooks_url
      return webhooks_plaid_eu_url if Rails.env.production?

      ENV.fetch("DEV_WEBHOOKS_URL", root_url.chomp("/")) + "/webhooks/plaid_eu"
    end
end
