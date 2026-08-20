module SnaptradeItem::Provided
  extend ActiveSupport::Concern

  included do
    before_destroy :capture_snaptrade_user_for_cleanup
    after_commit :delete_snaptrade_user, on: :destroy

    # A registered SnapTrade user belongs to the client that created it, so it
    # cannot survive a credential swap: the new client cannot see the old user,
    # and user_registered? would otherwise stay true and skip re-registration,
    # leaving every sync to fail with no recovery path.
    before_save :reset_registration_when_api_credentials_change
    after_commit :delete_rotated_snaptrade_user, on: :update
  end

  def snaptrade_provider
    return nil unless credentials_configured?

    Provider::Snaptrade.new(
      client_id: client_id,
      consumer_key: consumer_key
    )
  end

  def oauth_snaptrade_provider
    snaptrade_provider || Provider::Snaptrade.new
  end

  # Captured before the row goes away, so the cleanup below can still run after
  # the transaction has committed.
  def capture_snaptrade_user_for_cleanup
    @snaptrade_user_cleanup =
      if user_registered? && credentials_configured?
        { user_id: snaptrade_user_id, client_id: client_id, consumer_key: consumer_key }
      end
    true
  end

  # Clean up the SnapTrade user once the item is really gone.
  #
  # Runs after_commit rather than before_destroy: delete_user is a network call
  # wrapped in with_retries, which can sleep 2s + 4s + 8s on top of a 30s
  # timeout per attempt. Inside the destroy transaction that held row locks on
  # snaptrade_items and every cascading association for up to two minutes.
  #
  # Deliberately not a background job: the credentials are encrypted at rest and
  # passing them as job arguments would write them to the queue store in plain
  # text.
  def delete_snaptrade_user
    cleanup = @snaptrade_user_cleanup
    @snaptrade_user_cleanup = nil
    return unless cleanup

    Rails.logger.info "SnapTrade: Deleting user #{cleanup[:user_id]} for family #{family_id}"

    provider = Provider::Snaptrade.new(
      client_id: cleanup[:client_id],
      consumer_key: cleanup[:consumer_key]
    )
    provider.delete_user(user_id: cleanup[:user_id])

    Rails.logger.info "SnapTrade: Successfully deleted user #{cleanup[:user_id]}"
  rescue => e
    # Log but don't block deletion - user may not exist or credentials may be invalid
    Rails.logger.warn "SnapTrade: Failed to delete user #{cleanup[:user_id]}: #{e.class} - #{e.message}"
  end

  def reset_registration_when_api_credentials_change
    return if new_record?
    return unless will_save_change_to_client_id? || will_save_change_to_consumer_key?
    return if snaptrade_user_id.blank?

    # Captured before clearing: the upstream user survives the rotation, and
    # only the *previous* client can see or delete it. orphaned_users lists the
    # new client's users, so without this the old one holds a connection slot
    # that nothing can ever reclaim.
    @rotated_snaptrade_user = {
      user_id: snaptrade_user_id,
      client_id: client_id_was,
      consumer_key: consumer_key_was
    }

    Rails.logger.info "SnaptradeItem #{id} - API credentials changed, clearing stale SnapTrade user registration"
    self.snaptrade_user_id = nil
    self.snaptrade_user_secret = nil
  end

  # Delete the upstream user left behind by a credential rotation, using the
  # credentials it was registered under. Same after_commit reasoning as
  # delete_snaptrade_user: off the transaction, and not a background job
  # because job arguments would put the credentials in the queue store.
  def delete_rotated_snaptrade_user
    rotated = @rotated_snaptrade_user
    @rotated_snaptrade_user = nil
    return unless rotated
    return if rotated.values.any?(&:blank?)

    Rails.logger.info "SnaptradeItem #{id} - deleting SnapTrade user #{rotated[:user_id]} left by a credential rotation"

    Provider::Snaptrade.new(
      client_id: rotated[:client_id],
      consumer_key: rotated[:consumer_key]
    ).delete_user(user_id: rotated[:user_id])
  rescue => e
    Rails.logger.warn "SnapTrade: Failed to delete rotated user #{rotated&.dig(:user_id)}: #{e.class} - #{e.message}"
  end

  # User ID and secret for SnapTrade API calls
  def snaptrade_credentials
    return nil unless snaptrade_user_id.present? && snaptrade_user_secret.present?

    {
      user_id: snaptrade_user_id,
      user_secret: snaptrade_user_secret
    }
  end

  # Check if user is registered with SnapTrade
  def user_registered?
    snaptrade_user_id.present? && snaptrade_user_secret.present?
  end

  # Register user with SnapTrade if not already registered
  # Returns true if registration succeeded or already registered
  # If existing credentials are invalid (user was deleted), clears them and re-registers
  def ensure_user_registered!
    # If we think we're registered, verify the user still exists
    if user_registered?
      case verify_user_status
      when :ok
        return true
      when :missing
        # User was deleted from SnapTrade API - clear local credentials and re-register
        Rails.logger.warn "SnapTrade: User #{snaptrade_user_id} no longer exists, clearing credentials and re-registering"
        update!(snaptrade_user_id: nil, snaptrade_user_secret: nil)
      else
        # Rate limit, 5xx or any other transient failure. The user_secret is
        # only ever returned at registration, so discarding it here on a blip
        # would orphan a working connection permanently. Keep it and let the
        # caller retry.
        raise Provider::Snaptrade::ApiError.new(
          "SnapTrade user verification is temporarily unavailable. Please try again."
        )
      end
    end

    provider = snaptrade_provider
    raise StandardError, "SnapTrade provider not configured" unless provider

    # Use family ID with current timestamp to ensure uniqueness (avoids conflicts from previous deletions)
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

    # Check if user already exists (shouldn't happen with timestamp suffix, but handle gracefully)
    if e.message.include?("already registered") || e.message.include?("already exists")
      Rails.logger.warn "SnapTrade: User already exists. Generating new unique ID."
      raise StandardError, "User registration conflict. Please try again."
    end

    raise
  end

  # Verify that the stored user actually exists in SnapTrade.
  # :ok      - the user answered for these credentials
  # :missing - SnapTrade rejected the credentials, so the user is really gone
  # :unknown - the check could not be completed (rate limit, 5xx, unconfigured)
  #
  # The distinction matters: only :missing may cost the caller its stored
  # snaptrade_user_secret, which SnapTrade returns exactly once at registration
  # and can never be read back.
  def verify_user_status
    return :unknown if snaptrade_user_id.blank?

    provider = snaptrade_provider
    return :unknown unless provider

    # Try to list connections - this will fail with 401/403 if user doesn't exist
    provider.list_connections(
      user_id: snaptrade_user_id,
      user_secret: snaptrade_user_secret
    )
    :ok
  rescue Provider::Snaptrade::AuthenticationError => e
    Rails.logger.warn "SnapTrade: User verification failed - #{e.message}"
    :missing
  rescue Provider::Snaptrade::ApiError => e
    Rails.logger.warn "SnapTrade: User verification could not be completed - #{e.message}"
    :unknown
  end

  # Get the connection portal URL for linking brokerages
  def connection_portal_url(redirect_url:, broker: nil)
    raise StandardError, "User not registered with SnapTrade" unless user_registered?

    provider = snaptrade_provider
    raise StandardError, "SnapTrade provider not configured" unless provider

    provider.get_connection_url(
      user_id: snaptrade_user_id,
      user_secret: snaptrade_user_secret,
      redirect_url: redirect_url,
      broker: broker
    )
  end

  def start_oauth_device_flow(scope: "read")
    oauth_snaptrade_provider.start_device_authorization(scope: scope)
  end

  def complete_oauth_device_flow!(device_code:)
    token_response = oauth_snaptrade_provider.poll_device_token(device_code: device_code)
    update!(
      oauth_access_token: token_response["access_token"],
      oauth_refresh_token: token_response["refresh_token"],
      oauth_token_type: token_response["token_type"],
      oauth_scope: token_response["scope"],
      oauth_token_expires_at: token_response["expires_in"].present? ? Time.current + token_response["expires_in"].to_i.seconds : nil
    )
    token_response
  end

  # Fetch all brokerage connections from SnapTrade API
  # Returns array of connection objects
  def fetch_connections
    return [] unless credentials_configured? && user_registered?

    provider = snaptrade_provider
    creds = snaptrade_credentials
    provider.list_connections(user_id: creds[:user_id], user_secret: creds[:user_secret])
  rescue Provider::Snaptrade::ApiError => e
    Rails.logger.error "SnaptradeItem #{id} - Failed to list connections: #{e.message}"
    raise
  end

  # List all SnapTrade users registered under this client ID
  def list_all_users
    return [] unless credentials_configured?

    snaptrade_provider.list_users
  rescue Provider::Snaptrade::ApiError => e
    Rails.logger.error "SnaptradeItem #{id} - Failed to list users: #{e.message}"
    []
  end

  # Find orphaned SnapTrade users (registered but not current user)
  def orphaned_users
    return [] unless credentials_configured? && user_registered?

    all_users = list_all_users
    all_users.select { |uid| uid != snaptrade_user_id && uid.start_with?("family_#{family_id}_") }
  end

  # Delete an orphaned SnapTrade user and all their connections
  def delete_orphaned_user(user_id)
    return false unless credentials_configured?
    return false if user_id == snaptrade_user_id # Don't delete current user
    return false unless user_id.start_with?("family_#{family_id}_")

    snaptrade_provider.delete_user(user_id: user_id)
    true
  rescue Provider::Snaptrade::ApiError => e
    Rails.logger.error "SnaptradeItem #{id} - Failed to delete orphaned user #{user_id}: #{e.message}"
    false
  end
end
