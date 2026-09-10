class Provider::FinancekitAdapter < Provider::Base
  Provider::Factory.register("FinancekitAccount", self)

  def self.supported_account_types
    %w[Depository CreditCard]
  end

  def provider_name
    "financekit"
  end

  def item
    provider_account.financekit_item
  end

  def metadata
    super.merge(delivery: "device_push", last_device_contact_at: item.last_device_contact_at,
      last_accepted_at: item.last_accepted_at, last_imported_at: item.last_imported_at)
  end
end
