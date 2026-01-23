module SnaptradeItem::Provided
  extend ActiveSupport::Concern

  included do
    before_destroy :delete_snaptrade_user
  end

  def snaptrade_provider
    return nil unless credentials_configured?

    Provider::Snaptrade.new(
      client_id: client_id,
      consumer_key: consumer_key
    )
  end

  # Clean up SnapTrade user when item is destroyed
  def delete_snaptrade_user
    return unless user_registered?

    provider = snaptrade_provider
    return unless provider

    Rails.logger.info "SnapTrade: Deleting user #{snaptrade_user_id} for family #{family_id}"

    provider.delete_user(user_id: snaptrade_user_id)

    Rails.logger.info "SnapTrade: Successfully deleted user #{snaptrade_user_id}"
  rescue => e
    # Log but don't block deletion - user may not exist or credentials may be invalid
    Rails.logger.warn "SnapTrade: Failed to delete user #{snaptrade_user_id}: #{e.class} - #{e.message}"
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
      if verify_user_exists?
        return true
      else
        # User was deleted from SnapTrade API - clear local credentials and re-register
        Rails.logger.warn "SnapTrade: User #{snaptrade_user_id} no longer exists, clearing credentials and re-registering"
        update!(snaptrade_user_id: nil, snaptrade_user_secret: nil)
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

  # Verify that the stored user actually exists in SnapTrade
  # Returns false if user doesn't exist, credentials are invalid, or verification fails
  def verify_user_exists?
    return false unless snaptrade_user_id.present?

    provider = snaptrade_provider
    return false unless provider

    # Try to list connections - this will fail with 401/403 if user doesn't exist
    provider.list_connections(
      user_id: snaptrade_user_id,
      user_secret: snaptrade_user_secret
    )
    true
  rescue Provider::Snaptrade::AuthenticationError => e
    Rails.logger.warn "SnapTrade: User verification failed - #{e.message}"
    false
  rescue Provider::Snaptrade::ApiError => e
    # Return false on API errors - caller can retry registration if needed
    Rails.logger.warn "SnapTrade: User verification error - #{e.message}"
    false
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
    all_users.reject { |uid| uid == snaptrade_user_id }
  end

  # Delete an orphaned SnapTrade user and all their connections
  def delete_orphaned_user(user_id)
    return false unless credentials_configured?
    return false if user_id == snaptrade_user_id # Don't delete current user

    snaptrade_provider.delete_user(user_id: user_id)
    true
  rescue Provider::Snaptrade::ApiError => e
    Rails.logger.error "SnaptradeItem #{id} - Failed to delete orphaned user #{user_id}: #{e.message}"
    false
  end
end
