module SnaptradeItem::Provided
  extend ActiveSupport::Concern

  included do
    before_destroy :cleanup_snaptrade_authorization
  end

  # The API client for whichever auth model this item is connected under, or
  # nil when it is not connected. Both clients expose the same data methods and
  # return plain hashes, so callers do not have to care which one they got.
  def snaptrade_provider
    case auth_method
    when :device_flow then snaptrade_api_client
    when :legacy_oauth then Provider::SnaptradeOauth.new(self)
    end
  end

  # Device-flow client, bound to this family's API credentials and -- once
  # registration has run -- to its SnapTrade user.
  def snaptrade_api_client
    return nil unless api_credentials_configured?

    Provider::Snaptrade.new(
      client_id: client_id,
      consumer_key: consumer_key,
      user_id: snaptrade_user_id,
      user_secret: snaptrade_user_secret
    )
  end

  # The device flow authorizes against the deployment's public OAuth client id
  # alone, so it works before the family has entered any API credentials.
  def oauth_device_client
    snaptrade_api_client || Provider::Snaptrade.new
  end

  # User ID and secret for SnapTrade API calls
  def snaptrade_credentials
    return nil unless user_registered?

    {
      user_id: snaptrade_user_id,
      user_secret: snaptrade_user_secret
    }
  end

  # Check if a SnapTrade user has been registered against our API credentials
  def user_registered?
    snaptrade_user_id.present? && snaptrade_user_secret.present?
  end

  # Register a SnapTrade user if we don't have a working one already.
  # Returns true once the item has a usable user_id/user_secret pair.
  def ensure_user_registered!
    if user_registered?
      case verify_user_exists?
      when :ok
        return true
      when :missing
        # The user was deleted upstream, so the stored secret is dead weight:
        # clear it and register a replacement.
        Rails.logger.warn "SnapTrade: User #{snaptrade_user_id} no longer exists, clearing credentials and re-registering"
        update!(snaptrade_user_id: nil, snaptrade_user_secret: nil)
      else
        # Transient failure. user_secret is returned exactly once and cannot be
        # recovered, so never discard it on anything short of proof the user is
        # gone -- one rate-limit blip would otherwise orphan a working
        # connection permanently.
        raise Provider::Snaptrade::ApiError.new(
          "Could not verify the SnapTrade user right now. Please try again shortly."
        )
      end
    end

    provider = snaptrade_api_client
    raise StandardError, "SnapTrade provider not configured" unless provider

    # Family ID plus the current timestamp, so a re-registration after a
    # deletion never collides with the previous user id.
    unique_user_id = "family_#{family_id}_#{Time.current.to_i}"

    Rails.logger.info "SnapTrade: Registering user #{unique_user_id} for family #{family_id}"

    result = provider.register_user(unique_user_id)

    Rails.logger.info "SnapTrade: Successfully registered user #{result[:user_id]}"

    update!(
      snaptrade_user_id: result[:user_id],
      snaptrade_user_secret: result[:user_secret]
    )

    true
  rescue Provider::Snaptrade::ApiError => e
    Rails.logger.error "SnapTrade user registration failed: #{e.class} - #{e.message}"
    # Log status code but not response_body to avoid credential exposure
    Rails.logger.error "SnapTrade error details: status=#{e.status_code}" if e.respond_to?(:status_code)
    Rails.logger.debug { "SnapTrade response body: #{e.response_body&.truncate(500)}" } if e.respond_to?(:response_body)

    # Shouldn't happen with the timestamp suffix, but handle it gracefully
    if e.message.include?("already registered") || e.message.include?("already exists")
      Rails.logger.warn "SnapTrade: User already exists. Generating new unique ID."
      raise StandardError, "User registration conflict. Please try again."
    end

    raise
  end

  # Does the stored SnapTrade user still exist upstream?
  #   :ok      - the user answered a request
  #   :missing - SnapTrade rejected our credentials, so the user is gone
  #   :unknown - we could not tell (network, rate limit, 5xx)
  def verify_user_exists?
    return :missing unless user_registered?

    provider = snaptrade_api_client
    return :unknown unless provider

    provider.list_connections
    :ok
  rescue Provider::Snaptrade::AuthenticationError => e
    Rails.logger.warn "SnapTrade: User verification failed - #{e.message}"
    :missing
  rescue Provider::Snaptrade::ApiError => e
    Rails.logger.warn "SnapTrade: User verification error - #{e.message}"
    :unknown
  end

  # --- Device flow (current) ---

  def start_oauth_device_flow(scope: "read")
    oauth_device_client.start_device_authorization(scope: scope)
  end

  def complete_oauth_device_flow!(device_code:)
    token_response = oauth_device_client.poll_device_token(device_code: device_code)
    apply_oauth_tokens!(token_response)
    update!(status: :good)
    token_response
  end

  # --- DEPRECATED authorization-code + PKCE (#2747) ---

  # Exchange an authorization code for tokens. Only reachable when
  # re-authorizing a connection that was already made under the PKCE flow;
  # new connections go through the device flow above.
  def complete_oauth_exchange!(code:, redirect_uri:, code_verifier:)
    payload = Provider::SnaptradeOauth.exchange_code(
      code: code,
      redirect_uri: redirect_uri,
      code_verifier: code_verifier
    )
    apply_oauth_tokens!(payload)
    update!(status: :good)
    payload
  end

  # --- Shared ---

  # Get the connection portal URL for linking brokerages
  def connection_portal_url(redirect_url:, broker: nil)
    provider = snaptrade_provider
    raise StandardError, "SnapTrade is not authorized" unless provider
    raise StandardError, "User not registered with SnapTrade" if device_flow? && !user_registered?

    provider.get_connection_url(redirect_url: redirect_url, broker: broker)
  end

  # Fetch all brokerage connections from SnapTrade API. Returns Array<Hash>.
  def fetch_connections
    provider = snaptrade_provider
    return [] unless provider
    return [] if device_flow? && !user_registered?

    provider.list_connections
  rescue Provider::Snaptrade::ApiError => e
    Rails.logger.error "SnaptradeItem #{id} - Failed to list connections: #{e.message}"
    raise
  end

  # List all SnapTrade users registered under this family's client id
  def list_all_users
    return [] unless api_credentials_configured?

    snaptrade_api_client.list_users
  rescue Provider::Snaptrade::ApiError => e
    Rails.logger.error "SnaptradeItem #{id} - Failed to list users: #{e.message}"
    []
  end

  # SnapTrade users left behind by this family's earlier registrations. Each
  # one holds connection slots, so the settings panel offers to delete them.
  def orphaned_users
    return [] unless api_credentials_configured? && user_registered?

    list_all_users.select { |uid| uid != snaptrade_user_id && uid.start_with?("family_#{family_id}_") }
  end

  # Delete an orphaned SnapTrade user and all their connections
  def delete_orphaned_user(user_id)
    return false unless api_credentials_configured?
    return false if user_id == snaptrade_user_id # Don't delete current user
    return false unless user_id.start_with?("family_#{family_id}_")

    snaptrade_api_client.delete_user(user_id: user_id)
    true
  rescue Provider::Snaptrade::ApiError => e
    Rails.logger.error "SnaptradeItem #{id} - Failed to delete orphaned user #{user_id}: #{e.message}"
    false
  end

  private

    # Release whatever this item holds upstream when it is destroyed. Never
    # blocks deletion: the local record goes either way.
    def cleanup_snaptrade_authorization
      if legacy_oauth?
        revoke_oauth_tokens
      else
        delete_snaptrade_user
      end
    end

    def delete_snaptrade_user
      return unless user_registered?

      provider = snaptrade_api_client
      return unless provider

      Rails.logger.info "SnapTrade: Deleting user #{snaptrade_user_id} for family #{family_id}"

      provider.delete_user(user_id: snaptrade_user_id)

      Rails.logger.info "SnapTrade: Successfully deleted user #{snaptrade_user_id}"
    rescue => e
      # User may not exist or credentials may be invalid; log and move on
      Rails.logger.warn "SnapTrade: Failed to delete user #{snaptrade_user_id}: #{e.class} - #{e.message}"
    end

    def revoke_oauth_tokens
      token = oauth_refresh_token.presence || oauth_access_token # pipelock:ignore Credential in URL
      return if token.blank?

      Provider::SnaptradeOauth.revoke_token(token: token)
    rescue => e
      Rails.logger.warn "SnapTrade: Failed to revoke tokens for item #{id}: #{e.class} - #{e.message}"
    end
end
