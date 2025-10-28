class Provider::Factory
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
      adapter_class = registry[provider_type]

      # If not registered, try to load the adapter
      if adapter_class.nil?
        ensure_adapters_loaded
        adapter_class = registry[provider_type]
      end

      raise ArgumentError, "Unknown provider type: #{provider_type}. Did you forget to register it?" unless adapter_class

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
      registry.keys
    end

    # Ensures all provider adapters are loaded
    # This is needed for Rails autoloading in development/test environments
    def ensure_adapters_loaded
      return if @adapters_loaded

      # Require all adapter files to trigger registration
      Dir[Rails.root.join("app/models/provider/*_adapter.rb")].each do |file|
        require_dependency file
      end

      @adapters_loaded = true
    end

    private

      def registry
        @registry ||= {}
      end
  end
end
