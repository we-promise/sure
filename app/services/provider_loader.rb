# frozen_string_literal: true

# Service class to load SSO provider configurations from either YAML or database
# based on the AUTH_PROVIDERS_SOURCE environment setting.
#
# Usage:
#   providers = ProviderLoader.load_providers
#
class ProviderLoader
  CACHE_KEY = "sso_providers_config"
  CACHE_EXPIRES_IN = 5.minutes

  class << self
    # Load providers from either DB or YAML based on feature flag
    # Returns an array of provider configuration hashes
    def load_providers
      # Check cache first for performance
      cached = Rails.cache.read(CACHE_KEY)
      return cached if cached.present?

      providers = if use_database_providers?
        load_from_database
      else
        load_from_yaml
      end

      # Cache the result
      Rails.cache.write(CACHE_KEY, providers, expires_in: CACHE_EXPIRES_IN)
      providers
    end

    # Clear the provider cache (call after updating providers in admin)
    def clear_cache
      Rails.cache.delete(CACHE_KEY)
    end

    private
      def use_database_providers?
        return false if Rails.env.test?

        FeatureFlags.db_sso_providers?
      end

      def load_from_database
        begin
          providers = SsoProvider.enabled.order(:name).map(&:to_omniauth_config)

          if providers.empty?
            Rails.logger.info("[ProviderLoader] No enabled providers in database, falling back to YAML")
            return load_from_yaml
          end

          Rails.logger.info("[ProviderLoader] Loaded #{providers.count} provider(s) from database")
          providers
        rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
          Rails.logger.error("[ProviderLoader] Database error loading providers: #{e.message}, falling back to YAML")
          load_from_yaml
        rescue StandardError => e
          Rails.logger.error("[ProviderLoader] Unexpected error loading providers from database: #{e.message}, falling back to YAML")
          load_from_yaml
        end
      end

      def load_from_yaml
        begin
          auth_config = Rails.application.config_for(:auth)
          providers = auth_config.dig("providers") || []

          Rails.logger.info("[ProviderLoader] Loaded #{providers.count} provider(s) from YAML")
          providers
        rescue RuntimeError, Errno::ENOENT => e
          Rails.logger.error("[ProviderLoader] Error loading auth.yml: #{e.message}")
          []
        end
      end
  end
end
