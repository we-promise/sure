class PlaidItemsController < ApplicationController
  include StreamExtensions

  before_action :set_plaid_item, only: %i[edit destroy sync]
  before_action :require_admin!, only: %i[new create select_existing_account link_existing_account edit destroy sync]

  def new
    region = params[:region] == "eu" ? :eu : :us
    webhooks_url = region == :eu ? plaid_eu_webhooks_url : plaid_us_webhooks_url

    @link_token = Current.family.get_link_token(
      webhooks_url: webhooks_url,
      redirect_url: accounts_url,
      accountable_type: params[:accountable_type] || "Depository",
      region: region
    )
  rescue Plaid::ApiError => e
    handle_link_token_error(e)
  end

  def edit
    webhooks_url = @plaid_item.plaid_region == "eu" ? plaid_eu_webhooks_url : plaid_us_webhooks_url

    @link_token = @plaid_item.get_update_link_token(
      webhooks_url: webhooks_url,
      redirect_url: accounts_url,
    )
  rescue Plaid::ApiError => e
    handle_link_token_error(e)
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
      redirect_to account_path(@account), alert: t(".no_available_accounts")
    end
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    plaid_account = PlaidAccount.find(params[:plaid_account_id])

    # Verify the Plaid account belongs to this family's Plaid items
    unless Current.family.plaid_items.include?(plaid_account.plaid_item)
      redirect_to account_path(@account), alert: t(".invalid_account")
      return
    end

    # Verify the Plaid account is not already linked
    if plaid_account.account_provider.present? || plaid_account.account.present?
      redirect_to account_path(@account), alert: t(".already_linked")
      return
    end

    # Create the link via AccountProvider
    AccountProvider.create!(
      account: @account,
      provider: plaid_account
    )

    redirect_to accounts_path, notice: t(".success")
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

    # When `link_token/create` (or the update equivalent) raises, surface a
    # friendly alert to the user instead of letting the modal frame render
    # blank. Plaid configuration/product-access errors are the common case for
    # self-hosted users — without this, the Link modal simply never opens and
    # the only signal lives in server logs.
    def handle_link_token_error(error)
      error_body = safe_parse_plaid_error(error)
      error_code = error_body["error_code"].to_s

      Rails.logger.warn(
        "Plaid link_token request failed: #{error_code} - #{error_body['error_message']}"
      )
      Sentry.capture_exception(error) if defined?(Sentry)

      alert = friendly_link_token_alert(error_code, error_body["error_message"])

      respond_to do |format|
        format.html { redirect_to accounts_path, alert: alert }
        format.turbo_stream { stream_redirect_to(accounts_path, alert: alert) }
      end
    end

    def safe_parse_plaid_error(error)
      JSON.parse(error.response_body.to_s)
    rescue JSON::ParserError
      {}
    end

    # Plaid surfaces its own actionable copy on configuration / product-access
    # failures (e.g. "Your account is not enabled for the following products
    # [...]. To request access, visit dashboard.plaid.com..."). Those messages
    # are safe to show verbatim — they describe a Plaid-side config issue,
    # not user data. For everything else we fall back to a generic message
    # and rely on the log + Sentry trail.
    SHOWABLE_PLAID_ERROR_CODES = %w[
      INVALID_PRODUCT
      PRODUCTS_NOT_SUPPORTED
      NO_PRODUCTS_PERMISSION
      ADDITION_LIMIT
      INVALID_INSTITUTION
      INSTITUTION_NOT_ENABLED_IN_REGION
      INSTITUTION_NOT_SUPPORTED
    ].freeze

    def friendly_link_token_alert(error_code, error_message)
      if SHOWABLE_PLAID_ERROR_CODES.include?(error_code) && error_message.present?
        t("plaid_items.errors.link_token_with_message", message: error_message)
      else
        t("plaid_items.errors.link_token_generic")
      end
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
