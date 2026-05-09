# Connection-framework adapter for Plaid (US + EU regions).
#
# Registered once under provider_key "plaid". Region is a connection-level
# attribute stored on metadata["region"] — the adapter consults it when
# picking the right Provider::Plaid client. Connect-time region selection
# happens in the settings panel (two buttons) and via the bank-sync
# directory entries (one per region, both pointing at provider_key="plaid"
# with a region param).
#
# Provider::PlaidAdapter and Provider::PlaidEuAdapter are the legacy peers
# in app/models/provider/. After the framework cutover (PlaidItem dropped
# in 20260504200000_drop_legacy_plaid_tables) those classes are reduced to
# configuration shells: each holds a Provider::Configurable `configure do`
# block that registers one region's global app credentials with
# Provider::ConfigurationRegistry. All connection / sync / discover logic
# lives here.
class Provider::Plaid::Adapter
  extend Provider::ConnectionAdapter

  # Plaid type → Sure Accountable mapping.
  # https://plaid.com/docs/api/accounts/#account-type-schema
  TYPE_MAPPING = {
    "depository" => { accountable: Depository, subtype_mapping: {
      "checking" => "checking", "savings" => "savings", "hsa" => "hsa",
      "cd" => "cd", "money market" => "money_market"
    } },
    "credit" => { accountable: CreditCard, subtype_mapping: {
      "credit card" => "credit_card"
    } },
    "loan" => { accountable: Loan, subtype_mapping: {
      "mortgage" => "mortgage", "student" => "student", "auto" => "auto",
      "business" => "business", "home equity" => "home_equity",
      "line of credit" => "line_of_credit"
    } },
    "investment" => { accountable: Investment, subtype_mapping: {
      "brokerage" => "brokerage", "pension" => "pension", "retirement" => "retirement",
      "401k" => "401k", "roth 401k" => "roth_401k", "403b" => "403b", "457b" => "457b",
      "529" => "529_plan", "hsa" => "hsa", "mutual fund" => "mutual_fund",
      "roth" => "roth_ira", "ira" => "ira", "sep ira" => "sep_ira",
      "simple ira" => "simple_ira", "trust" => "trust", "ugma" => "ugma", "utma" => "utma"
    } }
  }.freeze

  def self.display_name = "Plaid"
  def self.description  = "Connect US and EU banks via Plaid"
  def self.brand_color  = "#000000"
  def self.beta?        = false

  # Plaid uses global app credentials (PLAID_CLIENT_ID / PLAID_SECRET via
  # Rails.application.config.x.plaid_*), not per-family BYOK.
  def self.requires_family_config? = false

  # Per-region cred-form mapping: each region's app credentials live in a
  # legacy ConfigurationRegistry entry keyed by provider_key. The framework
  # panel renders these forms inline (one per region) when the upstream
  # client isn't configured, and a Connect button when it is.
  def self.region_setup
    [
      { region: "us", label: "US", config_key: "plaid",
        client: -> { Provider::Registry.plaid_provider_for_region(:us) } },
      { region: "eu", label: "EU", config_key: "plaid_eu",
        client: -> { Provider::Registry.plaid_provider_for_region(:eu) } }
    ]
  end

  # Legacy ConfigurationRegistry entries owned by this adapter. The settings
  # controller filters these out of the global cred-form loop so they don't
  # render twice (they appear inline in the framework card instead).
  def self.legacy_config_keys = region_setup.map { |r| r[:config_key] }

  def self.connect_actions(family:)
    region_setup.filter_map do |r|
      next unless r[:client].call.present?
      {
        region: r[:region],
        label:  "Connect a #{r[:label]} bank",
        path:   Rails.application.routes.url_helpers.new_provider_link_path(provider_key: "plaid", region: r[:region])
      }
    end
  end

  def self.supported_account_types
    %w[Depository CreditCard Loan Investment]
  end

  def self.syncer_class          = Provider::Plaid::Syncer
  def self.auth_class            = Provider::Auth::EmbeddedLink
  def self.webhook_handler_class = Provider::Plaid::WebhookHandler

  # Plaid signs webhooks with a JWT in the Plaid-Verification header and
  # publishes the verification key via /webhook_verification_key/get. The
  # existing Provider::Plaid#validate_webhook! does the work; we just route
  # to the right region's client.
  def self.verify_webhook!(headers:, raw_body:)
    sig = headers["Plaid-Verification"] || headers["HTTP_PLAID_VERIFICATION"]
    raise Provider::Plaid::Adapter::WebhookSignatureMissing, "missing Plaid-Verification header" if sig.blank?

    region = headers["X-Provider-Region"] || extract_region_from_body(raw_body)
    Provider::Registry.plaid_provider_for_region(region).validate_webhook!(sig, raw_body)
  end

  WebhookSignatureMissing = Class.new(StandardError)

  # Plaid's webhook payload doesn't carry the region, so we infer it from the
  # connection (looking up by item_id). If that fails we default to :us — the
  # signature check would fail anyway if the wrong region's keys were used.
  def self.extract_region_from_body(raw_body)
    parsed = JSON.parse(raw_body) rescue {}
    item_id = parsed["item_id"]
    return :us if item_id.blank?
    conn = Provider::Connection.where("metadata->>'plaid_item_id' = ?", item_id).first
    (conn&.metadata&.[]("region") || "us").to_sym
  end

  # Bank-sync directory entries — one per configured region. Each entry's
  # new_account_path uses provider_key "plaid" plus a region query param
  # which the EmbeddedLink controller threads into start_link_flow.
  def self.connection_configs(family:)
    region_setup.filter_map do |r|
      next unless r[:client].call.present?
      {
        key:  "plaid_#{r[:region]}_directory",
        name: "Plaid (#{r[:label]})",
        description: "Connect to your #{r[:label]} bank via Plaid",
        new_account_path: ->(_accountable_type, _return_to) {
          Rails.application.routes.url_helpers.new_provider_link_path(provider_key: "plaid", region: r[:region])
        },
        existing_account_path: nil
      }
    end
  end

  def self.build_sure_account(provider_account, family:)
    type    = provider_account.external_type.to_s
    subtype = provider_account.external_subtype.to_s
    mapping = TYPE_MAPPING[type] ||
      raise(Provider::Account::UnsupportedAccountableType,
            "Provider::Plaid::Adapter does not handle external_type=#{type.inspect}")

    accountable_subtype = mapping[:subtype_mapping][subtype] || "other"
    accountable = mapping[:accountable].new(subtype: accountable_subtype)

    family.accounts.build(
      name:        provider_account.external_name,
      currency:    provider_account.currency,
      balance:     0,
      accountable: accountable
    )
  end

  # Translates Plaid::ApiError into a structured error the admin can act on.
  # Most common case: "OAuth redirect URI must be configured in the developer
  # dashboard" — we splice in the exact URL the admin needs to paste, and the
  # framework renders it as a copyable code block on /settings/providers.
  def self.humanize_link_error(error, redirect_uri:)
    return nil unless error.is_a?(Plaid::ApiError)

    body = JSON.parse(error.response_body.to_s) rescue {}
    code = body["error_code"]
    msg  = body["error_message"].to_s

    if code == "INVALID_FIELD" && msg.include?("OAuth redirect URI")
      {
        "message" => "Plaid rejected the request because your app's OAuth redirect URI " \
                     "list doesn't include this app's URL. Add the URL below to your " \
                     "Plaid Dashboard under API → Allowed redirect URIs, then try again.",
        "redirect_uri" => redirect_uri
      }
    elsif msg.present?
      { "message" => "Plaid: #{msg}" }
    else
      { "message" => "Plaid returned an error (#{code || error.class}). Check your dashboard configuration and try again." }
    end
  end

  # ---- EmbeddedLink contract --------------------------------------------

  def self.js_controller_name = "plaid"

  def self.start_link_flow(family:, flow_id:, params:, resume_url:, oauth_redirect_url:, webhooks_url:)
    if params[:connection_id].present?
      connection = family.provider_connections.find(params[:connection_id])
      region = connection.metadata["region"]
      kind = "update"
      access_token = connection.credentials["access_token"]
    else
      region = params[:region].to_s
      raise ArgumentError, "Unknown region: #{region.inspect}" unless %w[us eu].include?(region)
      kind = "new"
      access_token = nil
    end

    link_token = Provider::Registry.plaid_provider_for_region(region.to_sym).get_link_token(
      user_id:          family.id,
      webhooks_url:     webhooks_url,
      redirect_url:     oauth_redirect_url,
      accountable_type: params[:accountable_type],
      access_token:     access_token
    ).link_token

    state = {
      "kind"       => kind,
      "region"     => region,
      "link_token" => link_token,
      "created_at" => Time.current.to_i
    }
    state["connection_id"] = connection.id if kind == "update"
    state
  end

  def self.complete_link_flow(family:, flow:, params:)
    region = flow["region"]
    response = Provider::Registry.plaid_provider_for_region(region.to_sym)
                                  .exchange_public_token(params.require(:public_token))

    Provider::Connection.transaction do
      conn = family.provider_connections.create!(
        provider_key: "plaid",
        auth_type:    "embedded_link",
        status:       :healthy,
        credentials:  {},
        metadata: {
          "region"        => region,
          "plaid_item_id" => response.item_id
        }
      )
      conn.auth.store_access_token(response.access_token)
      conn
    end
  end

  def self.js_data_for(flow:, is_resume:, urls:)
    {
      controller:                     "plaid",
      plaid_link_token_value:         flow["link_token"],
      plaid_region_value:             flow["region"],
      plaid_is_update_value:          flow["kind"] == "update",
      plaid_is_resume_value:          is_resume,
      plaid_connection_id_value:      flow["connection_id"],
      # Server-supplied endpoints — the JS controller MUST NOT hardcode any.
      plaid_complete_url_value:       urls[:complete],
      plaid_sync_url_value:           urls[:sync],
      plaid_post_sync_redirect_value: urls[:post_sync_redirect]
    }
  end
end

Provider::ConnectionRegistry.register("plaid", Provider::Plaid::Adapter)
