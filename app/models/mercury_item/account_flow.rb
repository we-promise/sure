# frozen_string_literal: true

class MercuryItem::AccountFlow < ProviderItem::AccountFlow
  def self.cache_sensitive_params
    %i[token base_url]
  end

  private

    def provider_error_class
      Provider::Mercury::MercuryError
    end

    def resolve_item(id)
      MercuryItem.resolve_for(family: family, mercury_item_id: id)
    end

    def fetch_accounts
      provider = item&.mercury_provider
      raise NoApiTokenError unless provider.present?

      provider.get_accounts[:accounts] || []
    end

    def upsert_provider_account!(account_id, account_data)
      mercury_account = item.mercury_accounts.find_or_initialize_by(account_id: account_id.to_s)
      mercury_account.upsert_mercury_snapshot!(account_data)
      mercury_account
    end
end
