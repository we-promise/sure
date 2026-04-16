class OidcIdentity < ApplicationRecord
  belongs_to :user

  validates :provider, presence: true
  validates :uid, presence: true, uniqueness: { scope: :provider }
  validates :user_id, presence: true

  # Update the last authenticated timestamp
  def record_authentication!
    update!(last_authenticated_at: Time.current)
  end

  # Sync user attributes from IdP on each login
  # Updates stored identity info and syncs name to user (not email - that's identity)
  def sync_user_attributes!(auth)
    # Extract groups from claims (various common claim names)
    groups = extract_groups(auth)

    # Update stored identity info with latest from IdP
    update!(info: {
      email: auth.info&.email,
      name: auth.info&.name,
      first_name: auth.info&.first_name,
      last_name: auth.info&.last_name,
      groups: groups
    })

    # Sync name to user if provided (keep existing if IdP doesn't provide)
    user.update!(
      first_name: auth.info&.first_name.presence || user.first_name,
      last_name: auth.info&.last_name.presence || user.last_name
    )

    # Apply role mapping based on group membership
    apply_role_mapping!(groups)
  end

  # Extract groups from various common IdP claim formats
  def extract_groups(auth)
    # Try various common group claim locations
    groups = auth.extra&.raw_info&.groups ||
             auth.extra&.raw_info&.[]("groups") ||
             auth.extra&.raw_info&.[]("Group") ||
             auth.info&.groups ||
             auth.extra&.raw_info&.[]("http://schemas.microsoft.com/ws/2008/06/identity/claims/groups") ||
             auth.extra&.raw_info&.[]("cognito:groups") ||
             []

    # Normalize to array of strings
    Array(groups).map(&:to_s)
  end

  # Apply role mapping based on IdP group membership
  def apply_role_mapping!(groups)
    config = provider_config
    return unless config.present?

    role_mapping = config.dig(:settings, :role_mapping) || config.dig(:settings, "role_mapping")
    return unless role_mapping.present?

    # Check roles in order of precedence (highest to lowest)
    %w[super_admin admin member].each do |role|
      mapped_groups = role_mapping[role] || role_mapping[role.to_sym] || []
      mapped_groups = Array(mapped_groups)

      # Check if user is in any of the mapped groups
      if mapped_groups.include?("*") || (mapped_groups & groups).any?
        # Only update if different to avoid unnecessary writes
        user.update!(role: role) unless user.role == role
        Rails.logger.info("[SSO] Applied role mapping: user_id=#{user.id} role=#{role} groups=#{groups}")
        return
      end
    end
  end

  # Extract and store relevant info from OmniAuth auth hash
  def self.create_from_omniauth(auth, user)
    # Extract issuer from OIDC auth response if available
    issuer = auth.extra&.raw_info&.iss || auth.extra&.raw_info&.[]("iss")

    create!(
      user: user,
      provider: auth.provider,
      uid: auth.uid,
      issuer: issuer,
      info: {
        email: auth.info&.email,
        name: auth.info&.name,
        first_name: auth.info&.first_name,
        last_name: auth.info&.last_name
      },
      last_authenticated_at: Time.current
    )
  end

  # Find the configured provider for this identity
  def provider_config
    Rails.configuration.x.auth.sso_providers&.find { |p| p[:name] == provider || p[:id] == provider }
  end

  # Validate that the stored issuer matches the configured provider's issuer
  # Returns true if valid, false if mismatch (security concern)
  def issuer_matches_config?
    return true if issuer.blank? # Backward compatibility for old records

    config = provider_config
    return true if config.blank? || config[:issuer].blank? # No config to validate against

    issuer == config[:issuer]
  end
end
