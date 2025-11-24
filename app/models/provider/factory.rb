class Provider::Factory
  class AdapterNotFoundError < StandardError; end

  class << self
    # Register a provider adapter
    # @param provider_type [String] The provider account class name (e.g., "PlaidAccount")
    # @param adapter_class [Class] The adapter class (e.g., Provider::PlaidAdapter)
    def register(provider_type, adapter_class)
      registry[provider_type] = adapter_class
    end

    # Creates an adapter for a given provider account
    # @param provider_account [PlaidAccount, SimplefinAccount] The provider-specific account
    # @param account [Account] Optional account reference
    # @return [Provider::Base] An adapter instance
    def create_adapter(provider_account, account: nil)
      return nil if provider_account.nil?

      provider_type = provider_account.class.name
      adapter_class = find_adapter_class(provider_type)

      raise AdapterNotFoundError, "No adapter registered for provider type: #{provider_type}" unless adapter_class

      adapter_class.new(provider_account, account: account)
    end

    # Creates an adapter from an AccountProvider record
    # @param account_provider [AccountProvider] The account provider record
    # @return [Provider::Base] An adapter instance
    def from_account_provider(account_provider)
      return nil if account_provider.nil?

      create_adapter(account_provider.provider, account: account_provider.account)
    end

    # Get list of registered provider types
    # @return [Array<String>] List of registered provider type names
    def registered_provider_types
      ensure_adapters_loaded
      registry.keys.sort
    end

    # Ensures all provider adapters are loaded and registered
    # Uses Rails autoloading to discover adapters dynamically
    def ensure_adapters_loaded
      # Eager load all adapter files to trigger their registration
      adapter_files.each do |adapter_name|
        adapter_class_name = "Provider::#{adapter_name}"

        # Use Rails autoloading (constantize) instead of require
        begin
          adapter_class_name.constantize
        rescue NameError => e
          Rails.logger.warn("Failed to load adapter: #{adapter_class_name} - #{e.message}")
        end
      end
    end

    # Check if a provider type has a registered adapter
    # @param provider_type [String] The provider account class name
    # @return [Boolean]
    def registered?(provider_type)
      find_adapter_class(provider_type).present?
    end

    # Get all registered adapter classes
    # @return [Array<Class>] List of registered adapter classes
    def registered_adapters
      ensure_adapters_loaded
      registry.values.uniq
    end

    # Get adapters that support a specific account type
    # @param account_type [String] The account type class name (e.g., "Depository", "CreditCard")
    # @return [Array<Class>] List of adapter classes that support this account type
    def adapters_for_account_type(account_type)
      registered_adapters.select do |adapter_class|
        adapter_class.supported_account_types.include?(account_type)
      end
    end

    # Check if any provider supports a given account type
    # @param account_type [String] The account type class name
    # @return [Boolean]
    def supports_account_type?(account_type)
      adapters_for_account_type(account_type).any?
    end

    # Get all available provider connection configs for a given account type
    # @param account_type [String] The account type class name (e.g., "Depository")
    # @param family [Family] The family to check connection availability for
    # @return [Array<Hash>] Array of connection configurations from all providers
    def connection_configs_for_account_type(account_type:, family:)
      adapters_for_account_type(account_type).flat_map do |adapter_class|
        adapter_class.connection_configs(family: family)
      end
    end

    # Clear all registered adapters (useful for testing)
    def clear_registry!
      @registry = {}
    end

    private

      def registry
        @registry ||= {}
      end

      # Find adapter class, attempting to load all adapters if not registered
      def find_adapter_class(provider_type)
        # Return if already registered
        return registry[provider_type] if registry[provider_type]

        # Load all adapters to ensure they're registered
        # This triggers their self-registration calls
        ensure_adapters_loaded

        # Check registry again after loading
        registry[provider_type]
      end

      # Discover all adapter files in the provider directory
      # Returns adapter class names (e.g., ["PlaidAdapter", "SimplefinAdapter"])
      def adapter_files
        return [] unless defined?(Rails)

        pattern = Rails.root.join("app/models/provider/*_adapter.rb")
        Dir[pattern].map do |file|
          File.basename(file, ".rb").camelize
        end
      end
  end
end
