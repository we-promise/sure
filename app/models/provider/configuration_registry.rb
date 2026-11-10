# Registry to store all provider configurations. Kept in its own autoloadable
# file so Setting writes can load metadata before any adapter/controller.
module Provider::ConfigurationRegistry
  class << self
    def register(provider_key, configuration, adapter_class = nil)
      registry[provider_key] = configuration
      adapter_registry[provider_key] = adapter_class if adapter_class
    end

    def get(provider_key)
      registry[provider_key]
    end

    def all
      registry.values
    end

    # An incomplete registry must not permit plaintext writes.
    def secret_setting_keys
      if Thread.current[:loading_provider_secret_metadata]
        raise Setting::SecretError, "Provider secret metadata is unavailable"
      end

      begin
        Thread.current[:loading_provider_secret_metadata] = true
        Provider::Factory.ensure_adapters_loaded(strict: true)
        all.flat_map(&:fields).select(&:secret).map { |field| field.setting_key.to_s }.uniq
      ensure
        Thread.current[:loading_provider_secret_metadata] = nil
      end
    rescue StandardError
      raise Setting::SecretError, "Provider secret metadata is unavailable", cause: nil
    end

    def providers
      registry.keys
    end

    def get_adapter_class(provider_key)
      adapter_registry[provider_key]
    end

    private
      def registry
        @registry ||= {}
      end

      def adapter_registry
        @adapter_registry ||= {}
      end
  end
end
