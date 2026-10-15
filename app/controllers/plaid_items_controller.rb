class PlaidItemsController < ApplicationController
  include StreamExtensions, ConnectorAuthorizable

  connects_provider PlaidItem

  before_action :set_plaid_item, only: %i[edit destroy sync]
  before_action :require_connector_create!, only: %i[new create select_existing_account link_existing_account]
  before_action :require_connector_manage!, only: %i[edit destroy sync]

  def new
    region = normalized_region(params[:region])
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
      account_selection_enabled: @plaid_item.us? && params[:add_accounts] == "true",
    )
  rescue Plaid::ApiError => e
    handle_link_token_error(e)
  end

  # Plaid Link on the web holds back every event but OPEN and LAYER_* until the end of
  # the flow, delivering them alongside onSuccess, so the browser never gets a chance
  # to step in before the user authenticates. This is the last point where a duplicate
  # connection can still be stopped: the Item exists at Plaid once Link issues the
  # public token, but an access token -- what counts against a Trial plan's Item
  # limit, which /item/remove never gives back -- only exists once we exchange it.
  # Plaid's duplicate-Items guidance is exactly this: compare the onSuccess metadata
  # with the user's existing Items, and do not exchange a duplicate.
  def create
    unless params[:confirm_duplicate] == "1"
      duplicate_items = matching_plaid_items(
        normalized_region(plaid_item_params[:region]),
        institution_id: institution_id,
        institution_name: item_name
      )

      return render_duplicate_warning(duplicate_items) if duplicate_items.any?
    end

    Current.family.create_plaid_item!(
      public_token: plaid_item_params[:public_token],
      item_name: item_name,
      region: plaid_item_params[:region],
      institution_id: institution_id
    )

    # A stream for the JavaScript's fetch rather than a plain redirect: fetch follows
    # a redirect by itself, and that discarded GET would consume the flash before the
    # page navigates.
    respond_to do |format|
      format.html { redirect_to accounts_path, notice: t(".success") }
      format.turbo_stream { stream_redirect_to(accounts_path, notice: t(".success")) }
    end
  rescue Plaid::ApiError => e
    handle_exchange_error(e)
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
    # `metadata.institution.institution_id`. `presence` because the duplicate
    # warning's form sends the id back through a hidden field, which turns a missing
    # id into an empty string -- and an empty string is not an id to store.
    def institution_id
      plaid_item_params.dig(:metadata, :institution, :institution_id).presence
    end

    # Anything but an explicit "eu" is the US region, the same default the Link opener
    # falls back to. Reading the value raw would query `plaid_region IS NULL` whenever
    # a caller omits it, and the duplicate lookup would silently match nothing.
    def normalized_region(value)
      value == "eu" ? :eu : :us
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

    # Matches on institution_id when both sides have one, and otherwise on the
    # institution name: for items whose first sync never landed and so carry no
    # institution_id yet -- a broken connection is exactly what a user tries to
    # re-link -- and for Link metadata that leaves the id out. Only two known ids
    # that differ rule the name out; then a shared display name is a false positive
    # rather than a match.
    #
    # `plaid_items.name` is written once at create from Link's institution metadata and
    # never overwritten (there is no update route, and upsert_plaid_institution_snapshot!
    # does not assign it), so it stays comparable to the institution name that Link's
    # onSuccess metadata reports.
    def matching_plaid_items(region, institution_id:, institution_name:)
      name = normalized_institution_name(institution_name)

      connected_plaid_items(region).includes(:plaid_accounts).select do |item|
        if institution_id.present? && item.institution_id.present?
          item.institution_id == institution_id
        else
          name.present? && normalized_institution_name(item.name) == name
        end
      end
    end

    def normalized_institution_name(value)
      value.to_s.strip.downcase.presence
    end

    # A stream that swaps the Link opener in the modal frame for the warning. The
    # public token rides along in the warning's "Confirm this connection" form,
    # because nothing is exchanged unless the user asks for the connection after all.
    # A page can't render that stream, so a request that wants HTML goes back to
    # Accounts with the reason instead, and its token is never exchanged.
    def render_duplicate_warning(duplicate_items)
      respond_to do |format|
        format.html { redirect_to accounts_path, alert: t("plaid_items.create.already_connected") }
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "modal",
            partial: "plaid_items/duplicate_warning",
            locals: {
              duplicate_items: duplicate_items,
              account_overlap: PlaidItem::AccountOverlap.new(
                link_accounts: plaid_item_params.dig(:metadata, :accounts),
                plaid_items: duplicate_items
              ),
              public_token: plaid_item_params[:public_token],
              region: normalized_region(plaid_item_params[:region]).to_s,
              institution_name: item_name,
              institution_id: institution_id
            }
          )
        end
      end
    end

    # A held public token can expire while the duplicate warning sits open -- Plaid
    # gives it 30 minutes -- and Plaid reports an expired token and an already
    # exchanged one alike, as INVALID_PUBLIC_TOKEN. Either way the user has to go
    # through Link again, so say that instead of failing with an error page.
    def handle_exchange_error(error)
      error_body = safe_parse_plaid_error(error)
      error_code = error_body["error_code"].to_s
      token_expired = error_code == "INVALID_PUBLIC_TOKEN"

      DebugLogEntry.capture(
        category: "provider_auth",
        level: token_expired ? "warn" : "error",
        message: "Plaid public token exchange failed: #{error_code.presence || error.class.name}",
        source: "PlaidItemsController#create",
        provider_key: "plaid",
        family: Current.family,
        user: Current.user,
        metadata: {
          error_code: error_code.presence,
          request_id: error_body["request_id"],
          region: plaid_item_params[:region]
        }
      )

      alert = token_expired ? t("plaid_items.create.token_expired") : t("plaid_items.create.exchange_failed")

      respond_to do |format|
        format.html { redirect_to accounts_path, alert: alert }
        format.turbo_stream { stream_redirect_to(accounts_path, alert: alert) }
      end
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
        format.html do
          if turbo_frame_request?
            render_frame_redirect(accounts_path, alert: alert)
          else
            redirect_to accounts_path, alert: alert
          end
        end
        format.turbo_stream { stream_redirect_to(accounts_path, alert: alert) }
      end
    end

    # The Link flow is opened inside the "modal" turbo frame. A plain redirect
    # is followed within that frame, so the flash is spent on a response whose
    # body is discarded and the modal just closes. Answer with the frame itself
    # carrying a redirect stream action, which performs a full-page visit.
    def render_frame_redirect(path, alert:)
      flash[:alert] = alert

      render html: helpers.turbo_frame_tag(turbo_frame_request_id) {
        helpers.turbo_stream.action(:redirect, path)
      }
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
