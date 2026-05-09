# OAuth2 grant lifecycle for a Provider::Connection.
#
# The public surface splits into two categories — callers should know which
# side of the line they're on:
#
#   READ-ONLY (build URLs, return strings; never write to @connection):
#     authorize_url, reauth_url
#
#   MUTATING (persist new tokens / status to @connection.credentials):
#     exchange_code, fresh_access_token (via refresh!), store_tokens
#
# Methods below the "Mutators" header all call @connection.update! and may
# transition status to :requires_update on consent revocation. fresh_access_token
# is a read in the happy path but mutates if the access_token is expired.
class Provider::Auth::OAuth2
  def initialize(connection)
    @connection = connection
  end

  # ---- Read-only ---------------------------------------------------------

  def authorize_url(redirect_uri:, state:)
    adapter_config.authorize_url(
      client_id:    family_credentials[:client_id],
      redirect_uri: redirect_uri,
      state:        state,
      scope:        adapter_config.scopes,
      sandbox:      @connection.metadata["sandbox"]
    )
  end

  def reauth_url(state:)
    adapter = Provider::ConnectionRegistry.adapter_for(@connection.provider_key)
    if adapter.respond_to?(:reauth_url)
      adapter.reauth_url(@connection, redirect_uri: persisted_redirect_uri, state: state)
    else
      authorize_url(redirect_uri: persisted_redirect_uri, state: state)
    end
  end

  # ---- Mutators ----------------------------------------------------------

  # redirect_uri is persisted on @connection.metadata at first authorize and
  # MUST exactly match that value on token exchange — provider OAuth servers
  # reject the exchange otherwise (e.g., "invalid_grant").
  def exchange_code(code:)
    tokens = adapter_config.token_client(family_credentials, sandbox: sandbox?).exchange(code: code, redirect_uri: persisted_redirect_uri)
    consent_expiry = adapter_config.fetch_consent_expiry(@connection, tokens.access_token)
    store_tokens(tokens, consent_expires_at: consent_expiry)
  end

  # Returns the current access_token. Refreshes (and mutates @connection)
  # transparently if the stored token has expired.
  def fresh_access_token
    refresh! if expired?
    @connection.credentials["access_token"]
  end

  def store_tokens(tokens, consent_expires_at: nil)
    new_metadata = @connection.metadata.dup
    new_metadata["consent_expires_at"] = consent_expires_at.iso8601 if consent_expires_at

    @connection.update!(
      credentials: @connection.credentials.merge(
        "access_token"  => tokens.access_token,
        # Some providers omit refresh_token on refresh responses (only access_token rotates).
        # Preserve the previously stored value rather than nulling future refreshes.
        "refresh_token" => tokens.refresh_token.presence || @connection.credentials["refresh_token"],
        "expires_at"    => (Time.current + tokens.expires_in.seconds).to_i
      ),
      metadata: new_metadata
    )
  end

  private

    def refresh!
      tokens = begin
        fetch_new_tokens
      rescue Provider::Auth::ConsentExpiredError, Provider::Auth::TokenRevokedError
        @connection.update!(status: :requires_update, sync_error: "reauth_required")
        raise Provider::Auth::ReauthRequiredError
      end
      store_tokens(tokens)
    end

    def fetch_new_tokens
      adapter_config.token_client(family_credentials, sandbox: sandbox?)
                    .refresh(@connection.credentials["refresh_token"])
    end

    def expired?
      return true if @connection.credentials["expires_at"].blank?
      Time.current >= Time.at(@connection.credentials["expires_at"].to_i - 60)
    end

    def sandbox?
      @connection.metadata["sandbox"]
    end

    def persisted_redirect_uri
      @connection.metadata["redirect_uri"].presence ||
        raise(Provider::Auth::ReauthRequiredError, "missing redirect_uri on connection #{@connection.id}")
    end

    # Today every OAuth adapter is BYOK (per-family client_id/secret stored in
    # Provider::FamilyConfig). The `provider_family_config_id` FK is nullable
    # so future adapters can use globally-configured Rails credentials, but
    # those adapters MUST override this method (or this class). Failing loudly
    # here documents the contract for the next adapter.
    def family_credentials
      config = @connection.provider_family_config
      raise NotImplementedError,
        "Provider '#{@connection.provider_key}' has no provider_family_config; " \
        "non-BYOK OAuth providers must override family_credentials" unless config
      { client_id: config.client_id, client_secret: config.client_secret }
    end

    def adapter_config
      Provider::ConnectionRegistry.config_for(@connection.provider_key)
    end
end
