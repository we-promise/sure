# frozen_string_literal: true

class SsoProvider < ApplicationRecord
  include Encryptable
  extend SslConfigurable

  # Encrypt sensitive credentials if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :client_secret, deterministic: false
  end

  # Default enabled to true for new providers
  attribute :enabled, :boolean, default: true

  # Validations
  validates :strategy, presence: true, inclusion: {
    in: %w[openid_connect google_oauth2 github saml],
    message: "%{value} is not a supported strategy"
  }
  validates :name, presence: true, uniqueness: true, format: {
    with: /\A[a-z0-9_]+\z/,
    message: "must contain only lowercase letters, numbers, and underscores"
  }
  validates :label, presence: true
  validates :enabled, inclusion: { in: [ true, false ] }
  validates :icon, format: {
    with: /\A\S+\z/,
    message: "cannot be blank or contain only whitespace"
  }, allow_nil: true

  before_validation :normalize_icon

  # Strategy-specific validations
  validate :validate_oidc_fields, if: -> { strategy == "openid_connect" }
  validate :validate_oauth_fields, if: -> { strategy.in?(%w[google_oauth2 github]) }
  validate :validate_saml_fields, if: -> { strategy == "saml" }
  validate :validate_default_role_setting
  # Note: OIDC discovery validation is done client-side via Stimulus
  # Server-side validation can fail due to network issues, so we skip it
  # validate :validate_oidc_discovery, if: -> { strategy == "openid_connect" && issuer.present? && will_save_change_to_issuer? }

  # Scopes
  scope :enabled, -> { where(enabled: true) }
  scope :by_strategy, ->(strategy) { where(strategy: strategy) }

  # Convert to hash format compatible with OmniAuth initializer
  def to_omniauth_config
    {
      id: name,
      strategy: strategy,
      name: name,
      label: label,
      icon: icon.present? && icon.strip.present? ? icon.strip : nil,
      issuer: issuer,
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      settings: settings || {}
    }.compact
  end

  private
    def normalize_icon
      self.icon = icon.to_s.strip.presence
    end

    def validate_oidc_fields
      if issuer.blank?
        errors.add(:issuer, "is required for OpenID Connect providers")
      elsif issuer.present? && !valid_url?(issuer)
        errors.add(:issuer, "must be a valid URL")
      end

      errors.add(:client_id, "is required for OpenID Connect providers") if client_id.blank?
      errors.add(:client_secret, "is required for OpenID Connect providers") if client_secret.blank?

      if redirect_uri.present? && !valid_url?(redirect_uri)
        errors.add(:redirect_uri, "must be a valid URL")
      end
    end

    def validate_oauth_fields
      errors.add(:client_id, "is required for OAuth providers") if client_id.blank?
      errors.add(:client_secret, "is required for OAuth providers") if client_secret.blank?
    end

    def validate_saml_fields
      # SAML requires either a metadata URL or manual configuration
      idp_metadata_url = settings&.dig("idp_metadata_url")
      idp_sso_url = settings&.dig("idp_sso_url")

      if idp_metadata_url.blank? && idp_sso_url.blank?
        errors.add(:settings, "Either IdP Metadata URL or IdP SSO URL is required for SAML providers")
      end

      # If using manual config, require certificate
      if idp_metadata_url.blank? && idp_sso_url.present?
        idp_cert = settings&.dig("idp_certificate")
        idp_fingerprint = settings&.dig("idp_cert_fingerprint")

        if idp_cert.blank? && idp_fingerprint.blank?
          errors.add(:settings, "Either IdP Certificate or Certificate Fingerprint is required when not using metadata URL")
        end
      end

      # Validate URL formats if provided
      if idp_metadata_url.present? && !valid_url?(idp_metadata_url)
        errors.add(:settings, "IdP Metadata URL must be a valid URL")
      end

      if idp_sso_url.present? && !valid_url?(idp_sso_url)
        errors.add(:settings, "IdP SSO URL must be a valid URL")
      end
    end

    def validate_default_role_setting
      default_role = settings&.dig("default_role") || settings&.dig(:default_role)
      default_role = default_role.to_s
      return if default_role.blank?

      unless User.roles.key?(default_role)
        errors.add(:settings, "default_role must be guest, member, admin, or super_admin")
      end
    end

    def validate_oidc_discovery
      return unless issuer.present?

      begin
        discovery_url = issuer.end_with?("/") ? "#{issuer}.well-known/openid-configuration" : "#{issuer}/.well-known/openid-configuration"
        response = Faraday.new(ssl: self.class.faraday_ssl_options).get(discovery_url) do |req|
          req.options.timeout = 5
          req.options.open_timeout = 3
        end

        unless response.success?
          errors.add(:issuer, "discovery endpoint returned #{response.status}")
          return
        end

        discovery_data = JSON.parse(response.body)
        unless discovery_data["issuer"].present?
          errors.add(:issuer, "discovery endpoint did not return valid issuer")
        end
      rescue Faraday::Error => e
        errors.add(:issuer, "could not connect to discovery endpoint: #{e.message}")
      rescue JSON::ParserError
        errors.add(:issuer, "discovery endpoint returned invalid JSON")
      rescue StandardError => e
        errors.add(:issuer, "discovery validation failed: #{e.message}")
      end
    end

    def valid_url?(url)
      uri = URI.parse(url)
      uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    rescue URI::InvalidURIError
      false
    end
end
