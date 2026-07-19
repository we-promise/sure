class PropertiesController < ApplicationController
  include AccountableResource, StreamExtensions

  before_action :set_property, only: [ :balances, :address, :update_balances, :update_address ]
  before_action :require_property_write_permission!, only: [ :update_balances, :update_address ]

  def new
    @account = Current.family.accounts.build(accountable: Property.new)
    @avm_providers = configured_avm_providers
  end

  def create
    return create_via_avm_provider if params[:avm_provider].present?

    @account = Current.family.accounts.create!(
      property_params.merge(
        balance: 0,
        status: "draft",
        owner: Current.user,
        currency: property_params[:currency].presence || Current.family.currency
      )
    )
    @account.auto_share_with_family! if Current.family.share_all_by_default?

    redirect_to balances_property_path(@account)
  end

  def update
    if @account.update(property_params)
      @success_message = "Property details updated successfully."

      if @account.active?
        render :edit
      else
        redirect_to balances_property_path(@account)
      end
    else
      @error_message = "Unable to update property details."
      render :edit, status: :unprocessable_entity
    end
  end

  def edit
  end

  def balances
  end

  def update_balances
    result = nil
    Account.transaction do
      @account.update!(currency: balance_params[:currency]) if balance_params[:currency].present?
      result = @account.set_current_balance(balance_params[:balance].to_d)
      raise ActiveRecord::Rollback unless result.success?
    end

    if result&.success?
      @success_message = "Balance updated successfully."

      if @account.active?
        render :balances
      else
        redirect_to address_property_path(@account)
      end
    else
      @error_message = result&.error_message
      render :balances, status: :unprocessable_entity
    end
  end

  def address
    @property = @account.property
    @property.address ||= Address.new
  end

  def update_address
    if @account.property.update(address_params)
      if @account.draft?
        @account.activate!

        # The property setup wizard (create → balances → address) is multi-step,
        # so the original `?return_to=` only survives in the session (captured by
        # StoreLocation), not as a threaded form param. Honor it on completion so
        # flows like the savings-goals "Add an account" CTA land back where they
        # started instead of on the account page. Sanitized + consumed: the
        # turbo_stream branch below isn't covered by Rails' redirect host-guard,
        # so an unsafe value must not reach stream_redirect_to.
        return_path = safe_return_to(session.delete(:return_to)) || account_path(@account)

        respond_to do |format|
          format.html { redirect_to return_path }
          format.turbo_stream { stream_redirect_to return_path }
        end
      else
        @success_message = "Address updated successfully."
        render :address
      end
    else
      @error_message = "Unable to update address. Please check the required fields."
      render :address, status: :unprocessable_entity
    end
  end

  private
    def create_via_avm_provider
      @avm_providers = configured_avm_providers
      provider_key = params[:avm_provider].to_s

      unless @avm_providers.map(&:to_s).include?(provider_key)
        redirect_to new_property_path, alert: t("providers.property_valuation.not_configured") and return
      end

      if params[:avm_step] == "confirm"
        # The signed token proves the lookup step actually ran (and spent its
        # provider request) — a direct confirm POST with fabricated data
        # would otherwise create provider-linked properties that the daily
        # refresh job then spends quota on. Everything is rebuilt from the
        # token payload, so nothing user-editable is trusted.
        payload = verify_avm_preview_token!

        importer = Property::AvmImport.new(
          family: Current.family,
          owner: Current.user,
          provider_key: payload["provider_key"],
          name: payload["name"],
          address_attributes: payload["address"].symbolize_keys
        )

        @account = importer.create_account(avm_data_from_payload(payload))

        # The provider lookup fills in what the manual wizard's balance and
        # address steps would have collected, so the account is complete —
        # land on the account page (or the flow that initiated the wizard).
        return_path = safe_return_to(session.delete(:return_to)) || account_path(@account)

        respond_to do |format|
          format.html { redirect_to return_path }
          format.turbo_stream { stream_redirect_to return_path }
        end
      else
        # Step 1: spend one provider request, then show the fetched data for
        # review before anything is created.
        importer = Property::AvmImport.new(
          family: Current.family,
          owner: Current.user,
          provider_key: provider_key,
          name: params.dig(:account, :name),
          address_attributes: avm_address_params.to_h.symbolize_keys
        )

        @avm_preview = importer.lookup
        @avm_preview_token = avm_preview_verifier.generate(
          {
            "provider_key" => provider_key,
            "name" => params.dig(:account, :name),
            "address" => avm_address_params.to_h,
            "data" => @avm_preview.to_h.transform_values(&:to_s)
          },
          expires_in: 1.hour
        )
        @avm_provider_key = provider_key
        @account = Current.family.accounts.build(name: params.dig(:account, :name), accountable: Property.new)
        @avm_address = Address.new(avm_address_params.to_h)
        render :new
      end
    rescue Property::AvmImport::Error => error
      @avm_provider_key = provider_key
      @error_message = error.message
      @account = Current.family.accounts.build(name: params.dig(:account, :name), accountable: Property.new)
      # The confirm step doesn't resubmit the address fields, so build
      # defensively — an expired token re-renders an empty lookup form.
      @avm_address = Address.new(params.dig(:account, :address)&.permit(:line1, :locality, :region, :postal_code)&.to_h || {})
      render :new, status: :unprocessable_entity
    end

    def avm_address_params
      params.require(:account).require(:address).permit(:line1, :locality, :region, :postal_code)
    end

    def avm_preview_verifier
      Rails.application.message_verifier(:avm_preview)
    end

    def verify_avm_preview_token!
      avm_preview_verifier.verify(params[:avm_preview_token].to_s)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise Property::AvmImport::Error.new(t("providers.property_valuation.preview_expired"))
    end

    # Rebuilds the valuation data from the signed preview payload (values
    # were stringified for serialization; blanks were nil).
    def avm_data_from_payload(payload)
      raw = payload["data"] || {}

      Provider::PropertyValuationConcept::PropertyValuation.new(
        valuation: raw["valuation"].to_d,
        currency: raw["currency"].presence || "USD",
        property_type: raw["property_type"].presence,
        year_built: raw["year_built"].presence&.to_i,
        area_value: raw["area_value"].presence&.to_i,
        area_unit: raw["area_unit"].presence || "sqft"
      )
    end

    def configured_avm_providers
      registry = Provider::Registry.for_concept(:property_valuations)
      registry.provider_keys.select { |key| registry.get_provider(key).present? }
    end

    def balance_params
      params.require(:account).permit(:balance, :currency)
    end

    def address_params
      params.require(:property)
            .permit(address_attributes: [ :line1, :line2, :locality, :region, :country, :postal_code ])
    end

    def property_params
      params.require(:account)
            .permit(
              :name,
              :currency,
              :accountable_type,
              :institution_name,
              :institution_domain,
              :notes,
              accountable_attributes: [ :id, :subtype, :year_built, :area_unit, :area_value ]
            )
    end

    def set_property
      @account = accessible_accounts.find(params[:id])
      @property = @account.property
    end

    def require_property_write_permission!
      require_account_permission!(@account)
    end
end
