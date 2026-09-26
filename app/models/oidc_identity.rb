class OidcIdentity < ApplicationRecord
  class ProviderNotConfigured < StandardError; end
  class IssuerMismatch < StandardError; end
  class LegacyIdentityRebindRejected < StandardError; end

  belongs_to :user

  validates :provider, presence: true
  validates :uid, presence: true, uniqueness: { scope: :provider }
  validates :user_id, presence: true

  def self.provider_config_for(provider_name)
    config = AuthConfig.sso_providers&.find do |raw_config|
      normalized = raw_config.deep_symbolize_keys
      normalized[:name].to_s == provider_name.to_s || normalized[:id].to_s == provider_name.to_s
    end&.deep_symbolize_keys
    return unless config

    if oidc_provider_config?(config, provider_name) && config[:issuer].blank?
      options = Oidc::ProviderOptionsBuilder.call(config)
      config = config.merge(issuer: options[:issuer]) if options&.dig(:issuer).present?
    end

    config
  end

  def self.oidc_provider_config?(config, provider_name = nil)
    return false if config.blank?

    strategy = config.deep_symbolize_keys[:strategy].to_s
    strategy == "openid_connect" || (strategy.blank? && provider_name.to_s == "openid_connect")
  end

  # The OIDC strategy merges verified ID-token claims into raw_info. Keep the
  # issuer from that response and require it to match the active provider.
  def self.verified_issuer_for!(auth, config)
    issuer = raw_issuer(auth)
    return issuer unless oidc_provider_config?(config, auth.provider)

    expected_issuer = config.deep_symbolize_keys[:issuer]
    raise IssuerMismatch if issuer.blank? || expected_issuer.blank? || issuer != expected_issuer

    issuer
  end

  def self.raw_issuer(auth)
    raw_info = auth.extra&.raw_info
    return unless raw_info

    raw_info[:iss] || raw_info["iss"] || (raw_info.iss if raw_info.respond_to?(:iss))
  end

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

    # Sync name to user only when Sure has nothing on file (first link, or an
    # admin blanked the field). Edits made inside Sure must survive subsequent
    # SSO logins — previously the IdP value won unconditionally and clobbered
    # any manually-edited name on every login (#1103).
    user.update!(
      first_name: user.first_name.presence || auth.info&.first_name.presence,
      last_name: user.last_name.presence || auth.info&.last_name.presence
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
    %w[super_admin admin member guest].each do |role|
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
    SsoIdentityBlock.with_identity_lock(provider: auth.provider, uid: auth.uid) do
      if SsoIdentityBlock.blocked?(provider: auth.provider, uid: auth.uid)
        raise SsoIdentityBlock::BlockedIdentity
      end

      config = provider_config_for(auth.provider)
      raise ProviderNotConfigured if config.blank?

      issuer = verified_issuer_for!(auth, config)

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
  end

  # Rebind a legacy OIDC identity only after the user proves ownership of the
  # Sure account that already owns the provider/uid pair.
  def self.rebind_legacy_issuer_from_omniauth!(auth, user)
    SsoIdentityBlock.with_identity_lock(provider: auth.provider, uid: auth.uid) do
      if SsoIdentityBlock.blocked?(provider: auth.provider, uid: auth.uid)
        raise SsoIdentityBlock::BlockedIdentity
      end

      config = provider_config_for(auth.provider)
      raise ProviderNotConfigured if config.blank?
      raise LegacyIdentityRebindRejected unless oidc_provider_config?(config, auth.provider)

      issuer = verified_issuer_for!(auth, config)
      identity = find_by(provider: auth.provider, uid: auth.uid)
      unless identity&.user_id == user.id && identity.issuer.blank?
        raise LegacyIdentityRebindRejected
      end

      identity.update!(issuer: issuer, last_authenticated_at: Time.current)
      identity.sync_user_attributes!(auth)
      identity
    end
  end

  # Find the configured provider for this identity
  def provider_config
    self.class.provider_config_for(provider)
  end

  # Validate that this identity still belongs to its active provider. OIDC
  # identities require a stored issuer because provider + uid alone cannot
  # establish issuer continuity after an in-place provider change.
  def issuer_matches_config?(config = provider_config)
    return false if config.blank?

    config = config.deep_symbolize_keys
    config_issuer = config[:issuer]
    if self.class.oidc_provider_config?(config, provider)
      return false if issuer.blank? || config_issuer.blank?
    else
      return true if issuer.blank? || config_issuer.blank?
    end

    issuer == config_issuer
  end
end
