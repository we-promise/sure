class Provider::PlaidProfile
  Profile = Data.define(:key, :region, :client_id, :secret, :environment, :label) do
    def configured?
      client_id.present? && secret.present? &&
        Provider::PlaidProfile::SUPPORTED_REGIONS.include?(region) &&
        Provider::PlaidProfile::SUPPORTED_ENVIRONMENTS.include?(environment)
    end
  end

  SUPPORTED_REGIONS = %w[us eu].freeze
  SUPPORTED_ENVIRONMENTS = %w[sandbox development production].freeze
  PROFILE_ENV_PATTERN = /\APLAID_PROFILE_([A-Z0-9_]+)_CLIENT_ID\z/

  class << self
    def configured_for_region(region)
      region = region.to_s

      ([ default_profile(region) ] + environment_profiles).compact
        .select { |profile| profile.region == region && profile.configured? }
        .uniq { |profile| profile.key }
    end

    def find(key, region:)
      configured_for_region(region).find { |profile| profile.key == key.to_s }
    end

    def find!(key, region:)
      find(key, region:).tap do |profile|
        next if profile

        raise Provider::Registry::Error,
          "Plaid profile '#{key}' is not configured for the #{region} region"
      end
    end

    private
      def default_profile(region)
        adapter = region.to_s == "eu" ? Provider::PlaidEuAdapter : Provider::PlaidAdapter

        Profile.new(
          key: "default",
          region: region.to_s,
          client_id: adapter.config_value(:client_id),
          secret: adapter.config_value(:secret),
          environment: adapter.config_value(:environment).to_s,
          label: "Default"
        )
      end

      # Additional profiles are deliberately environment-backed. Plaid secrets
      # should not be duplicated into ordinary application records, and this
      # keeps profile rotation compatible with the existing self-hosted setup.
      #
      # Example:
      #   PLAID_PROFILE_PRIMARY_CLIENT_ID=...
      #   PLAID_PROFILE_PRIMARY_SECRET=...
      #   PLAID_PROFILE_PRIMARY_ENV=production
      #   PLAID_PROFILE_PRIMARY_REGION=us
      def environment_profiles
        ENV.keys.filter_map do |env_key|
          match = PROFILE_ENV_PATTERN.match(env_key)
          next unless match

          profile_key = normalize_key(match[1])
          next if profile_key == "default"

          prefix = "PLAID_PROFILE_#{match[1]}"
          profile = Profile.new(
            key: profile_key,
            region: ENV.fetch("#{prefix}_REGION", "us").downcase,
            client_id: ENV[env_key],
            secret: ENV["#{prefix}_SECRET"],
            environment: (ENV["#{prefix}_ENV"] || ENV["#{prefix}_ENVIRONMENT"] || "sandbox").downcase,
            label: ENV["#{prefix}_LABEL"].presence || profile_key.humanize
          )

          profile if valid?(profile)
        end
      end

      def normalize_key(key)
        key.to_s.downcase.gsub(/[^a-z0-9]+/, "_").sub(/\A_+|_+\z/, "")
      end

      def valid?(profile)
        SUPPORTED_REGIONS.include?(profile.region) &&
          SUPPORTED_ENVIRONMENTS.include?(profile.environment) &&
          profile.client_id.present? && profile.secret.present?
      end
  end

end
