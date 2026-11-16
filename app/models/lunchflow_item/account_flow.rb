# frozen_string_literal: true

class LunchflowItem::AccountFlow < ProviderItem::AccountFlow
  def self.cache_sensitive_params
    %i[api_key base_url]
  end

  private

    def provider_error_class
      Provider::Lunchflow::LunchflowError
    end

    def resolve_item(id)
      LunchflowItem.resolve_for(family: family, lunchflow_item_id: id)
    end

    def fetch_accounts
      provider = item&.lunchflow_provider
      raise NoApiTokenError unless provider.present?

      provider.get_accounts[:accounts] || []
    end

    def provider_account_snapshot_changed?(lunchflow_account, account_data)
      lunchflow_account.raw_payload.to_h.deep_stringify_keys != account_data.to_h.deep_stringify_keys
    end

    # The app-wide translated subtype name, as Lunch Flow's setup page used.
    def subtype_label_default(type_key, key, _value)
      type_key.camelize.constantize.long_subtype_label_for(key)
    end

    def upsert_provider_account!(account_id, account_data)
      lunchflow_account = item.lunchflow_accounts.find_or_initialize_by(account_id: account_id.to_s)
      lunchflow_account.upsert_lunchflow_snapshot!(account_data)
      lunchflow_account
    end
end
