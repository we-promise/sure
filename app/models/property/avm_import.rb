# Creates a property account from an AVM provider lookup in two steps:
# `lookup` spends one provider request to fetch the property's attributes
# (type, year built, area) and estimated value, which the user reviews on a
# preview screen; `create_account` then seeds the account from the confirmed
# data without a second request.
class Property::AvmImport
  Error = Class.new(StandardError)

  def initialize(family:, owner:, provider_key:, name:, address_attributes:, external_id: nil)
    @family = family
    @owner = owner
    @provider_key = provider_key.to_s
    @name = name
    @address_attributes = address_attributes
    @external_id = external_id.to_s.strip.presence
  end

  # Step 1: validates the inputs, then spends one provider request. Returns
  # the fetched Provider::PropertyValuationConcept::PropertyValuation.
  def lookup
    validate_inputs!

    provider = Provider::Registry.for_concept(:property_valuations).get_provider(provider_key)
    raise Error.new(I18n.t("providers.property_valuation.not_configured")) if provider.nil?

    lookup_params = {
      line1: address_attributes[:line1],
      locality: address_attributes[:locality],
      region: address_attributes[:region],
      postal_code: address_attributes[:postal_code]
    }
    lookup_params[:external_id] = external_id if provider_class.requires_external_id?

    response = provider.fetch_property_valuation(**lookup_params)
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
          avm_external_id: data.external_id.presence || external_id,
          avm_last_synced_on: Date.current,
          # Each provider covers a single country, so the country isn't
          # collected in the lookup form.
          address_attributes: address_attributes.merge(country: provider_class.supported_country)
        )
      )

      result = account.set_current_balance(data.valuation)
      raise Error.new(result.error) unless result.success?
      account.property.name_avm_valuation!

      account.activate!
    end

    account.auto_share_with_family! if family.share_all_by_default?
    account
  rescue ActiveRecord::RecordInvalid => e
    raise Error.new(e.record.errors.full_messages.to_sentence.presence || e.message)
  end

  private
    attr_reader :family, :owner, :provider_key, :name, :address_attributes, :external_id

    def provider_class
      @provider_class ||= Provider::PropertyValuationConcept.provider_class(provider_key) ||
        raise(Error.new(I18n.t("providers.property_valuation.not_configured")))
    end

    # The form marks these required, but a forged or JS-less submission can
    # bypass that — validate locally before spending a monthly-budget request
    # on a lookup that can't produce a property.
    def validate_inputs!
      return unless name.blank? || !provider_class.lookup_ready?(address_attributes, external_id)

      message_key = provider_class.supported_country == "GB" ? "missing_fields_gb" : "missing_fields"
      raise Error.new(I18n.t("providers.property_valuation.#{message_key}"))
    end
end
