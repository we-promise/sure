# Registry of adapter classes that back Provider::Connection records.
# Auth-type agnostic: OAuth2 adapters (TrueLayer) and non-OAuth adapters
# (e.g. Plaid Link) register here by their provider_key string.
module Provider::ConnectionRegistry
  Error = Class.new(StandardError)

  class << self
    def register(key, adapter_class)
      registry[key.to_s] = adapter_class
    end

    def registered?(key)
      Provider::Factory.ensure_adapters_loaded
      registry.key?(key.to_s)
    end

    def keys
      Provider::Factory.ensure_adapters_loaded
      registry.keys
    end

    def adapter_for(key)
      Provider::Factory.ensure_adapters_loaded
      registry[key.to_s] or raise NotImplementedError, "No connection adapter registered for: #{key}"
    end

    # Resolves a framework key from either a framework key OR a legacy
    # config_key the adapter declares ownership of. Used by UI code that
    # only has the legacy key in hand (e.g. settings panel iterating
    # ConfigurationRegistry entries) and needs to find the framework adapter.
    def framework_key_for(any_key)
      Provider::Factory.ensure_adapters_loaded
      k = any_key.to_s
      registry.each do |framework_key, adapter|
        return framework_key if framework_key == k || adapter.legacy_config_keys.map(&:to_s).include?(k)
      end
      nil
    end

    def syncer_class_for(key)
      adapter = adapter_for(key)
      unless adapter.respond_to?(:syncer_class)
        raise NotImplementedError, "Adapter for '#{key}' (#{adapter}) does not define syncer_class"
      end
      adapter.syncer_class
    end

    def config_for(key)
      adapter_for(key).new(nil)
    end

    # Aggregates connection_configs across every registered adapter. Each
    # adapter is registered once; multi-variant adapters (e.g. Plaid: one
    # entry per region) return multiple configs from a single call.
    def all_connection_configs(family:)
      keys.flat_map { |key| adapter_for(key).connection_configs(family: family) }
    end

    private

      def registry
        @registry ||= {}
      end
  end
end
