# Class-method contract for adapters registered with Provider::ConnectionRegistry.
#
# Adapters extend this module to inherit defaults for optional methods and
# pick up NotImplementedError stubs that document the required surface:
#
#   class Provider::Truelayer::Adapter
#     extend Provider::ConnectionAdapter
#
#     def self.display_name = "TrueLayer"
#     def self.supported_account_types = %w[Depository CreditCard]
#     def self.syncer_class = Provider::Truelayer::Syncer
#     def self.connection_configs(family:) = [...]
#     def self.build_sure_account(provider_account, family:) = ...
#   end
#
# The module exists so the contract is grep-able (`extend Provider::ConnectionAdapter`
# at the top of every adapter is the entry point a reader can follow) and so adapter
# authors get a clear NotImplementedError pointing at the method they forgot, rather
# than the symptom downstream.
module Provider::ConnectionAdapter
  # ---- Required ----------------------------------------------------------

  # Human-readable provider name (e.g. "TrueLayer").
  def display_name
    raise NotImplementedError, "#{self} must define .display_name"
  end

  # Sure Accountable subclass names this provider produces (e.g. %w[Depository CreditCard]).
  # Used by the Add-Account flow to filter providers per accountable type.
  def supported_account_types
    raise NotImplementedError, "#{self} must define .supported_account_types"
  end

  # Syncer class instantiated as `syncer_class.new(connection)` by Provider::Connection#syncer.
  # The syncer must implement #perform_sync(sync) and #discover_accounts_only.
  def syncer_class
    raise NotImplementedError, "#{self} must define .syncer_class"
  end

  # Array of connection-config hashes consumed by the bank-sync directory.
  # Each hash describes one entry point (key, name, new_account_path lambda, etc.).
  def connection_configs(family:)
    raise NotImplementedError, "#{self} must define .connection_configs(family:)"
  end

  # Build (do NOT save) a Sure Account record from a Provider::Account.
  # Adapters own their external_type → Accountable mapping and any per-type
  # customisation (e.g. an investments adapter would build Holdings here).
  # Raise Provider::Account::UnsupportedAccountableType for types this adapter
  # doesn't handle, rather than silently mis-categorising.
  def build_sure_account(provider_account, family:)
    raise NotImplementedError, "#{self} must define .build_sure_account(provider_account, family:)"
  end

  # Auth backend used by Provider::Connection#auth to handle the credential
  # lifecycle (token exchange, refresh, reauth). OAuth2 adapters return
  # Provider::Auth::OAuth2; embedded-link adapters (e.g. Plaid Link) return
  # Provider::Auth::EmbeddedLink. The class must accept (connection) on init.
  def auth_class
    raise NotImplementedError, "#{self} must define .auth_class"
  end

  # ---- Optional (with defaults) ------------------------------------------

  def beta? = false
  def brand_color = "#6B7280"
  def description = nil

  # Whether this provider stores per-family credentials (BYOK) in
  # provider_family_configs. OAuth-BYOK providers (e.g. TrueLayer) override
  # to true; providers using global app credentials (e.g. Plaid) leave this
  # false. The settings panel uses this flag to choose between BYOK config UI
  # and direct connect-button UI.
  def requires_family_config? = false

  # Buttons rendered in the settings panel's "connect" area. Adapters that
  # need to ask the user a question before launching the link flow (e.g.
  # Plaid: "US bank or EU bank?") return one entry per choice. Default empty
  # — the panel falls back to its OAuth/BYOK flow.
  def connect_actions(family:)
    []
  end

  # Translates a vendor-specific exception raised during the link flow into
  # a structured error rendered on /settings/providers as a prominent block
  # (NOT the small toast — these messages can be long and can include a URL
  # the admin must copy into the upstream dashboard).
  #
  # Returns a Hash with string keys, or nil. nil means the adapter can't
  # (or shouldn't) translate — the controller re-raises so Rails' error
  # page surfaces the bug to the developer.
  #
  #   {
  #     "message"      => "Plaid rejected ...",  # required, long-form OK
  #     "redirect_uri" => "https://app.example.com/.../",  # optional, copyable
  #   }
  #
  # `redirect_uri` arg is the upstream-facing redirect URL prefix already
  # computed by the controller — adapters splice it into the result hash
  # so the admin sees exactly what to paste into the upstream dashboard.
  def humanize_link_error(error, redirect_uri:)
    nil
  end

  # OAuth2-only: extracts the sandbox flag (if any) from the family config
  # so OauthCallbacksController can pass `sandbox:` into authorize_url. This
  # lives on the adapter rather than the controller because the storage
  # location of the flag is provider-specific (TrueLayer puts it on
  # FamilyConfig.credentials; a future provider might use a different shape).
  def sandbox_for(config) = false

  # Per-region setup metadata for adapters that have a regional split with
  # distinct app credentials per region (e.g. Plaid: US + EU each have their
  # own client_id/secret). Each entry is a Hash with :region, :label,
  # :config_key (legacy ConfigurationRegistry provider_key) and :client (a
  # -> { } that returns the upstream client when configured, else nil).
  # Default empty — single-region adapters don't need this.
  def region_setup = []

  # Legacy ConfigurationRegistry provider_keys that the framework card owns
  # (rendered inline). The settings controller filters these out of the
  # global cred-form loop. Default empty.
  def legacy_config_keys = []

  # Provider-specific reauth URL (e.g. TrueLayer /v1/reauthuri). Return nil
  # to fall back to the standard authorize URL with the persisted redirect_uri.
  def reauth_url(connection, redirect_uri:, state:)
    nil
  end

  # Verifies the upstream webhook signature and raises if invalid. Adapters
  # that don't accept webhooks can leave this raising. Webhooks::ProviderController
  # calls this before dispatching to the handler.
  def verify_webhook!(headers:, raw_body:)
    raise NotImplementedError, "#{self} does not accept webhooks"
  end

  # Class implementing #process and accepting (connection:, raw_body:, headers:).
  # Webhooks::ProviderController instantiates and calls #process after signature
  # verification succeeds.
  def webhook_handler_class
    raise NotImplementedError, "#{self} does not accept webhooks"
  end

  # ---- EmbeddedLink contract (for adapters with auth_class == Provider::Auth::EmbeddedLink)

  # Starts a new link-token session. Returns a flow state Hash that
  # EmbeddedLinkCallbacksController stashes in session[:provider_flows] under
  # flow_id. Must include "link_token". Arbitrary other keys are preserved
  # and handed back to .complete_link_flow.
  #
  # params[:connection_id] (when present) signals update/reauth mode — the
  # adapter should issue a link_token bound to the existing connection's
  # access_token.
  #
  # oauth_redirect_url: fixed, pre-registerable callback URL for providers
  # whose embedded widget internally redirects to OAuth banks (e.g. Plaid).
  # Adapters that don't need this can ignore it.
  def start_link_flow(family:, flow_id:, params:, resume_url:, oauth_redirect_url:, webhooks_url:)
    raise NotImplementedError, "#{self} must define .start_link_flow for EmbeddedLink flows"
  end

  # Completes a link-token session. Receives the consumed flow state hash and
  # the request params (notably public_token). Performs the upstream exchange,
  # creates and returns a Provider::Connection on the family.
  def complete_link_flow(family:, flow:, params:)
    raise NotImplementedError, "#{self} must define .complete_link_flow for EmbeddedLink flows"
  end

  # Stimulus controller name mounted on the embedded-link view. Different
  # vendors ship different SDKs (Plaid Link, MX Connect Widget, Yodlee
  # FastLink); each has its own JS controller.
  def js_controller_name
    raise NotImplementedError, "#{self} must define .js_controller_name for EmbeddedLink flows"
  end

  # Hash of data-* attributes the embedded-link view renders on the controller
  # mount node — e.g. { controller: "plaid", plaid_link_token_value: "...",
  # plaid_is_resume_value: true }. Adapter-owned because each vendor's JS
  # controller has its own data-value naming.
  #
  # `urls` is a Hash of pre-computed route URLs the adapter may need, supplied
  # by the controller (which has request context). Keys today: :complete (POST
  # public_token), :sync (POST sync on existing connection), :post_sync_redirect
  # (where to navigate after a sync completes). Adapters MUST NOT call
  # Rails.application.routes themselves — the controller is the routing seam.
  def js_data_for(flow:, is_resume:, urls:)
    raise NotImplementedError, "#{self} must define .js_data_for for EmbeddedLink flows"
  end
end
