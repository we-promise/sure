module Provider
  class Base
    attr_reader :provider_account, :account

    def initialize(provider_account, account: nil)
      @provider_account = provider_account
      @account = account || provider_account.account
    end

    # Provider identification
    def provider_name
      raise NotImplementedError, "#{self.class} must implement #provider_name"
    end

    def provider_type
      provider_account.class.name
    end

    # Sync-related methods
    def sync_path
      raise NotImplementedError, "#{self.class} must implement #sync_path"
    end

    def item
      raise NotImplementedError, "#{self.class} must implement #item"
    end

    def syncing?
      item&.syncing? || false
    end

    # Account metadata
    def can_delete_holdings?
      false
    end

    def institution_domain
      nil
    end

    def institution_name
      nil
    end

    def institution_url
      nil
    end

    # Provider-specific data
    def raw_payload
      provider_account.raw_payload
    end

    def metadata
      {
        provider_name: provider_name,
        provider_type: provider_type,
        institution_domain: institution_domain,
        institution_name: institution_name
      }
    end
  end
end
