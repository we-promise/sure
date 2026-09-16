# Creates a property account from an AVM provider lookup in two steps:
# `lookup` spends one provider request to fetch the property's attributes
# (type, year built, area) and estimated value, which the user reviews on a
# preview screen; `create_account` then seeds the account from the confirmed
# data without a second request.
class Property::AvmImport
  Error = Class.new(StandardError)

  def initialize(family:, owner:, provider_key:, name:, address_attributes:)
    @family = family
    @owner = owner
    @provider_key = provider_key.to_s
    @name = name
    @address_attributes = address_attributes
  end

  # Step 1: validates the inputs, then spends one provider request. Returns
  # the fetched Provider::PropertyValuationConcept::PropertyValuation.
  def lookup
    validate_inputs!

    provider = Provider::Registry.for_concept(:property_valuations).get_provider(provider_key)
    raise Error.new(I18n.t("providers.property_valuation.not_configured")) if provider.nil?

    response = provider.fetch_property_valuation(
      line1: address_attributes[:line1],
      locality: address_attributes[:locality],
      region: address_attributes[:region],
      postal_code: address_attributes[:postal_code]
    )
    raise Error.new(response.error.message) unless response.success?

    response.data
  end

  # Step 2: creates the active property account from the user-confirmed
  # valuation data. No provider request is made here.
  def create_account(data)
    validate_inputs!

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

    # The form marks these required, but a forged or JS-less submission can
    # bypass that — validate locally before spending a monthly-budget request
    # on a lookup that can't produce a property.
    def validate_inputs!
      missing = name.blank? ||
        %i[line1 locality region postal_code].any? { |field| address_attributes[field].blank? }

      raise Error.new(I18n.t("providers.property_valuation.missing_fields")) if missing
    end
end
