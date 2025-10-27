module Provider
  class Factory
    class << self
      # Creates an adapter for a given provider account
      # @param provider_account [PlaidAccount, SimplefinAccount] The provider-specific account
      # @param account [Account] Optional account reference
      # @return [Provider::Base] An adapter instance
      def create_adapter(provider_account, account: nil)
        return nil if provider_account.nil?

        adapter_class = adapter_for(provider_account.class.name)
        adapter_class.new(provider_account, account: account)
      end

      # Creates an adapter from an AccountProvider record
      # @param account_provider [AccountProvider] The account provider record
      # @return [Provider::Base] An adapter instance
      def from_account_provider(account_provider)
        return nil if account_provider.nil?

        create_adapter(account_provider.provider, account: account_provider.account)
      end

      private

      def adapter_for(provider_type)
        case provider_type
        when "PlaidAccount"
          Provider::PlaidAdapter
        when "SimplefinAccount"
          Provider::SimplefinAdapter
        else
          raise ArgumentError, "Unknown provider type: #{provider_type}"
        end
      end
    end
  end
end
