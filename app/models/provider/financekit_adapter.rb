class Provider::FinancekitAdapter < Provider::Base
  include Provider::InstitutionMetadata
  Provider::Factory.register("FinancekitAccountLineage", self)

  def self.supported_account_types
    %w[Depository CreditCard]
  end

  def provider_name
    "financekit"
  end

  def item
    provider_account.financekit_accounts.joins(:financekit_item)
      .where(financekit_items: { status: %w[active repair_required] })
      .order(created_at: :desc).first&.financekit_item
  end

  def metadata
    return super.merge(delivery: "background_publisher") unless item

    super.merge(delivery: "background_publisher", last_device_contact_at: item.last_device_contact_at,
      last_accepted_at: item.last_accepted_at, last_imported_at: item.last_imported_at,
      last_downstream_at: item.last_downstream_at, repair_required: item.status == "repair_required")
  end
end
