class Property < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "single_family_home" => { short: "Single Family Home", long: "Single Family Home" },
    "multi_family_home" => { short: "Multi-Family Home", long: "Multi-Family Home" },
    "condominium" => { short: "Condo", long: "Condominium" },
    "townhouse" => { short: "Townhouse", long: "Townhouse" },
    "investment_property" => { short: "Investment Property", long: "Investment Property" },
    "second_home" => { short: "Second Home", long: "Second Home" },
    "apartment" => { short: "Apartment", long: "Apartment" },
    "plot" => { short: "Plot", long: "Plot / Land" },
    "commercial" => { short: "Commercial", long: "Commercial Property" },
    "agri_land" => { short: "Agri Land", long: "Agricultural Land" }
  }.freeze

  has_one :address, as: :addressable, dependent: :destroy

  accepts_nested_attributes_for :address

  attribute :area_unit, :string, default: "sqft"

  class << self
    def icon
      "home"
    end

    def color
      "#06AED4"
    end

    def classification
      "asset"
    end
  end

  def area
    Measurement.new(area_value, area_unit) if area_value.present?
  end

  def purchase_price
    first_valuation_amount
  end

  def trend
    Trend.new(current: account.balance_money, previous: first_valuation_amount)
  end

  def balance_display_name
    "market value"
  end

  def opening_balance_display_name
    "original purchase price"
  end

  # Balance updates are recorded as "Manual value update" reconciliations;
  # rename the one an AVM provider just wrote so the activity feed shows
  # where the value came from. Account::ReconciliationManager resets the name
  # on any later write to that day's entry.
  def name_avm_valuation!(date = Date.current)
    return if avm_provider.blank?

    entry = account.entries.valuations.find_by(date: date)
    return unless entry&.entryable&.reconciliation?

    provider_name = I18n.t("properties.avm_providers.#{avm_provider}", default: avm_provider.titleize)
    entry.update!(name: I18n.t("providers.property_valuation.entry_name", provider: provider_name))
  end

  # Whether an unlinked property can be linked to the given AVM provider for
  # automatic refreshes. Only address-based providers qualify: ID-based
  # providers (Chimnie) need an identifier that only the create-time lookup
  # supplies. The account must already be in the provider's currency so a
  # refresh can't write a valuation in the wrong currency. Unlike the
  # create-time lookup, which always sets the country, a manual address may
  # omit it, so require one to confirm the property is in the provider's
  # country.
  def avm_linkable?(provider_key)
    return false if avm_provider.present? || address&.country.blank?

    provider_class = Provider::PropertyValuationConcept.provider_class(provider_key)
    return false if provider_class.nil? || provider_class.requires_external_id?

    account.currency == provider_class.valuation_currency && provider_class.lookup_ready?(address)
  end

  # Configured providers this property can be linked to.
  def linkable_avm_providers
    return [] if avm_provider.present?

    registry = Provider::Registry.for_concept(:property_valuations)
    registry.provider_keys.select { |key| avm_linkable?(key) && registry.get_provider(key).present? }
  end

  # Links the property to an AVM provider and runs its first valuation right
  # away. The link is kept only if that valuation succeeds; a failure (an
  # address the provider can't value, an exhausted monthly budget) reverts
  # it, so the property can still be linked to another provider instead of
  # being stuck on one that never worked. Returns whether the link was kept.
  #
  # Claiming and reverting are conditional updates, so overlapping link
  # attempts can't clear each other's link: only the attempt that claimed the
  # unlinked property runs the valuation, and the revert only applies while
  # that attempt's link is still unsynced.
  def link_avm_provider!(provider_key)
    raise ArgumentError, "#{provider_key} can't be linked to this property" unless avm_linkable?(provider_key)

    key = provider_key.to_s
    claimed = Property.where(id: id, avm_provider: nil)
                      .update_all(avm_provider: key, avm_last_synced_on: nil, updated_at: Time.current)
    return false unless claimed == 1

    SyncPropertyValuationsJob.perform_now(property_id: id, force: true)
    reload
    return true if avm_provider == key && avm_last_synced_on.present?

    Property.where(id: id, avm_provider: key, avm_last_synced_on: nil)
            .update_all(avm_provider: nil, updated_at: Time.current)
    reload
    false
  end

  private
    def first_valuation_amount
      account.entries.valuations.order(:date).first&.amount_money || account.balance_money
    end
end
