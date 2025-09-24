class Provider::Banks::Registry
  ProviderMeta = Data.define(:key, :display_name, :credential_fields, :capabilities, :provider_class, :mapper_class)

  class << self
    def providers
      [wise, mercury]
    end

    def keys
      providers.map(&:key)
    end

    def find(key)
      providers.find { |p| p.key == key.to_sym }
    end

    def get_instance(key, credentials)
      meta = find(key)
      raise ArgumentError, "Unknown bank provider: #{key}" unless meta
      meta.provider_class.new(credentials)
    end

    def get_mapper(key)
      meta = find(key)
      raise ArgumentError, "Unknown bank provider: #{key}" unless meta
      meta.mapper_class.new
    end

    # --- Provider registrations ---
    def wise
      ProviderMeta.new(
        key: :wise,
        display_name: "Wise",
        credential_fields: [ { key: :api_key, label: "API Key", type: :password } ],
        capabilities: %i[accounts transactions],
        provider_class: Provider::Banks::Wise,
        mapper_class: Provider::Banks::Wise::Mapper
      )
    end

    def mercury
      ProviderMeta.new(
        key: :mercury,
        display_name: "Mercury",
        credential_fields: [
          { key: :api_key, label: "API Key", type: :password },
          { key: :webhook_signing_secret, label: "Webhook Signing Secret", type: :password }
        ],
        capabilities: %i[accounts transactions webhooks],
        provider_class: Provider::Banks::Mercury,
        mapper_class: Provider::Banks::Mercury::Mapper
      )
    end
  end
end
