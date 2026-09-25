module PlaidItem::Provided
  extend ActiveSupport::Concern

  def plaid_provider
    return @plaid_provider if defined?(@plaid_provider)

    @plaid_provider = if plaid_profile.present? && plaid_profile != "default"
      Provider::Registry.plaid_provider_for_region(self.plaid_region, profile: plaid_profile)
    else
      Provider::Registry.plaid_provider_for_region(self.plaid_region)
    end
  end
end
