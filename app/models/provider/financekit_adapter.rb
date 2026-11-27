class Provider::FinancekitAdapter < Provider::Base
  include Provider::InstitutionMetadata
  Provider::Factory.register("FinancekitAccountLineage", self)

  def self.supported_account_types
    %w[Depository CreditCard]
  end

  # Wallet accounts report "Apple" (or an Apple product name) as the institution.
  # Matched exactly, not by prefix: "Apple Bank" is a different institution.
  # Anything not listed gets no domain rather than a guess.
  APPLE_INSTITUTION_NAMES = [ "apple", "apple inc", "apple card", "apple cash", "apple wallet" ].freeze
  APPLE_DOMAIN = "apple.com".freeze

  def provider_name
    "financekit"
  end

  # The mapping row keeps the name the device sent; the Account never receives it.
  # Read at display time, so accounts created before this existed pick it up too.
  def institution_name
    latest_mapping&.institution_name.to_s.strip.presence
  end

  def institution_domain
    normalized = institution_name.to_s.downcase.delete(".").squish
    APPLE_DOMAIN if APPLE_INSTITUTION_NAMES.include?(normalized)
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

  private

    def latest_mapping
      provider_account.financekit_accounts.order(created_at: :desc, mapping_version: :desc).first
    end
end
