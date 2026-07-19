# Creates a property account from an AVM provider lookup: one provider request
# fetches the property's attributes (type, year built, area) and estimated
# value, which seed the account in place of the manual entry wizard steps.
class Property::AvmImport
  Error = Class.new(StandardError)

  def initialize(family:, owner:, provider_key:, name:, address_attributes:)
    @family = family
    @owner = owner
    @provider_key = provider_key.to_s
    @name = name
    @address_attributes = address_attributes
  end

  def call
    provider = Provider::Registry.for_concept(:property_valuations).get_provider(provider_key)
    raise Error.new(I18n.t("providers.property_valuation.not_configured")) if provider.nil?

    response = provider.fetch_property_valuation(
      line1: address_attributes[:line1],
      locality: address_attributes[:locality],
      region: address_attributes[:region],
      postal_code: address_attributes[:postal_code]
    )
    raise Error.new(response.error.message) unless response.success?

    data = response.data

    account = nil
    Account.transaction do
      account = family.accounts.create!(
        name: name,
        balance: 0,
        currency: data.currency,
        status: "draft",
        owner: owner,
        accountable: Property.new(
          subtype: data.property_type,
          year_built: data.year_built,
          area_value: data.area_value,
          area_unit: data.area_unit,
          avm_provider: provider_key,
          avm_last_synced_on: Date.current,
          # Providers only cover US addresses, so the country isn't collected
          # in the lookup form. "US" matches the manual form's placeholder.
          address_attributes: address_attributes.merge(country: "US")
        )
      )

      result = account.set_current_balance(data.valuation)
      raise Error.new(result.error) unless result.success?

      account.activate!
    end

    account.auto_share_with_family! if family.share_all_by_default?
    account
  rescue ActiveRecord::RecordInvalid => e
    raise Error.new(e.record.errors.full_messages.to_sentence.presence || e.message)
  end

  private
    attr_reader :family, :owner, :provider_key, :name, :address_attributes
end
