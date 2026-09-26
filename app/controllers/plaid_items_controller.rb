class PlaidItemsController < ApplicationController
  include StreamExtensions, ConnectorAuthorizable

  connects_provider PlaidItem

  before_action :set_plaid_item, only: %i[edit destroy sync]
  before_action :require_connector_create!, only: %i[new create duplicate_warning select_existing_account link_existing_account]
  before_action :require_connector_manage!, only: %i[edit destroy sync]

  def new
    @region = normalized_region
    webhooks_url = @region == :eu ? plaid_eu_webhooks_url : plaid_us_webhooks_url

    # Institutions this user already connected, handed to Plaid Link so it can warn
    # at SELECT_INSTITUTION -- before the user authenticates, and before Plaid
    # creates an Item. `allow_institution` comes back from the "add a new connection"
    # override on that warning and suppresses it for a single pass.
    allowed_id = params[:allow_institution].presence
    allowed_name = normalized_institution_name(params[:allow_institution_name])

    existing_items = connected_plaid_items(@region).reject do |item|
      if item.institution_id.present?
        item.institution_id == allowed_id
      else
        allowed_name.present? && normalized_institution_name(item.name) == allowed_name
      end
    end

    @connected_institution_ids = existing_items.filter_map(&:institution_id)
    @connected_institution_names = existing_items
      .select { |item| item.institution_id.blank? }
      .filter_map { |item| normalized_institution_name(item.name) }

    @link_token = Current.family.get_link_token(
      webhooks_url: webhooks_url,
      redirect_url: accounts_url,
      accountable_type: params[:accountable_type] || "Depository",
      region: @region
    )
  rescue Plaid::ApiError => e
    handle_link_token_error(e)
  end

  # Reached from plaid_controller.js when Link reports SELECT_INSTITUTION for an
  # institution the user already has connected. Plaid creates the Item when Link
  # completes and the public token is issued -- not at /item/public_token/exchange --
  # so checking in `create` would be too late to save a Trial-plan Item slot, and
  # declining to exchange there is worse still: it strands an Item we hold no access
  # token for and can never remove. Hence the interception before authentication.
  def duplicate_warning
    @region = normalized_region
    @institution_id = params[:institution_id].presence
    @institution_name = params[:institution_name].presence
    @accountable_type = params[:accountable_type]

    @duplicate_items = matching_plaid_items(
      @region,
      institution_id: @institution_id,
      institution_name: @institution_name
    )

    # Nothing to warn about -- a stale or hand-crafted URL, or the connection was
    # removed between opening Link and picking the institution. Start a fresh Link
    # session rather than render an empty dialog: Link has already closed by now, so
    # a dead modal would leave the user with no way forward.
    if @duplicate_items.empty?
      redirect_to new_plaid_item_path(
        region: @region,
        accountable_type: @accountable_type,
        allow_institution: @institution_id,
        allow_institution_name: @institution_name
      )
    end
  end

  def edit
    webhooks_url = @plaid_item.plaid_region == "eu" ? plaid_eu_webhooks_url : plaid_us_webhooks_url

    @link_token = @plaid_item.get_update_link_token(
      webhooks_url: webhooks_url,
      redirect_url: accounts_url,
      account_selection_enabled: @plaid_item.us? && params[:add_accounts] == "true",
    )
  rescue Plaid::ApiError => e
    handle_link_token_error(e)
  end

  def create
    Current.family.create_plaid_item!(
      public_token: plaid_item_params[:public_token],
      item_name: item_name,
      region: plaid_item_params[:region],
      institution_id: institution_id
    )

    redirect_to accounts_path, notice: t(".success")
  end

  def destroy
    @plaid_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    @plaid_item.sync_later_with_provider_refresh

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @region = params[:region] || "us"

    # A non-admin reaches this action now, so the target account needs its own
    # check -- family membership alone is not authorisation to attach a feed to
    # someone else's account.
    return if !Current.user.admin? && !require_account_permission!(@account)

    # Get all Plaid accounts from this family's Plaid items for the specified region
    # that are not yet linked to any account. A member only sees the items they
    # own; an admin sees the family's.
    scope = Current.family.plaid_items.where(plaid_region: @region)
    scope = scope.owned_by(Current.user) unless Current.user.admin?

    @available_plaid_accounts = scope
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

    # Verify the Plaid account belongs to this family's Plaid items, and that
    # this user may act on that connection at all -- a member must not be able
    # to attach a connection someone else owns.
    unless Current.family.plaid_items.include?(plaid_account.plaid_item) &&
           plaid_account.plaid_item.manageable_by?(Current.user)
      redirect_to account_path(@account), alert: t(".invalid_account")
      return
    end

    return if !Current.user.admin? && !require_account_permission!(@account)

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

    # Link's `onSuccess` metadata nests the institution, so the id is at
    # `metadata.institution.institution_id`. Its `onEvent` metadata -- what
    # plaid_controller.js reads for SELECT_INSTITUTION -- is flat, at
    # `metadata.institution_id`. The two shapes genuinely differ; neither is a typo
    # for the other.
    def institution_id
      plaid_item_params.dig(:metadata, :institution, :institution_id)
    end

    # `new` and `duplicate_warning` have to agree on the region, and the value handed
    # to the Link opener partial has to match what the duplicate lookup queries.
    # params[:region] is absent whenever a user arrives without an explicit region,
    # so reading it raw would query `plaid_region IS NULL` and silently match nothing.
    def normalized_region
      params[:region] == "eu" ? :eu : :us
    end

    # Mirrors `select_existing_account`: admins keep oversight of every connection in
    # the family, a member sees only their own. PlaidItem declares
    # `credential_scope :per_connection` precisely because a member connecting their
    # own bank exposes nothing of anyone else's -- warning them about a housemate's
    # connection would invert that, and would be a false positive besides, since two
    # people linking their own logins at one bank hold two legitimate Items.
    def connected_plaid_items(region)
      scope = Current.family.plaid_items.active.where(plaid_region: region)
      scope = scope.owned_by(Current.user) unless Current.user.admin?
      scope.ordered
    end

    # Matches on institution_id, falling back to the stored institution name for items
    # whose first sync never landed and so carry no institution_id yet -- a broken
    # connection is exactly what a user tries to re-link. The fallback is restricted
    # to those rows on purpose: once an id is known and differs, a shared display name
    # is a false positive rather than a match.
    #
    # `plaid_items.name` is written once at create from Link's institution metadata and
    # never overwritten (there is no update route, and upsert_plaid_institution_snapshot!
    # does not assign it), so it stays comparable to the `institution_name` that
    # SELECT_INSTITUTION reports.
    def matching_plaid_items(region, institution_id:, institution_name:)
      name = normalized_institution_name(institution_name)

      connected_plaid_items(region).includes(:plaid_accounts).select do |item|
        if item.institution_id.present?
          institution_id.present? && item.institution_id == institution_id
        else
          name.present? && normalized_institution_name(item.name) == name
        end
      end
    end

    def normalized_institution_name(value)
      value.to_s.strip.downcase.presence
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
