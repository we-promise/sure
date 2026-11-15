require "test_helper"

class PropertiesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:property)
  end

  test "creates property in draft status and redirects to balances step" do
    assert_difference -> { Account.count } => 1 do
      post properties_path, params: {
        account: {
          name: "New Property",
          subtype: "house",
          currency: "EUR",
          institution_name: "Property Lender",
          institution_domain: "propertylender.example",
          notes: "Property notes",
          accountable_type: "Property",
          accountable_attributes: {
            year_built: 1990,
            area_value: 1200,
            area_unit: "sqft"
          }
        }
      }
    end

    created_account = Account.order(:created_at).last
    assert created_account.accountable.is_a?(Property)
    assert_equal "draft", created_account.status
    assert_equal 0, created_account.balance
    assert_equal "EUR", created_account.currency
    assert_equal "Property Lender", created_account[:institution_name]
    assert_equal "propertylender.example", created_account[:institution_domain]
    assert_equal "Property notes", created_account[:notes]
    assert_equal 1990, created_account.accountable.year_built
    assert_equal 1200, created_account.accountable.area_value
    assert_equal "sqft", created_account.accountable.area_unit
    assert created_account.accountable.user_set_area?, "a manually entered area should count as user-set"
    assert_redirected_to balances_property_path(created_account)
  end

  test "updates property overview" do
    assert_no_difference [ "Account.count", "Property.count" ] do
      patch property_path(@account), params: {
        account: {
          name: "Updated Property",
          institution_name: "Updated Lender",
          institution_domain: "updatedlender.example",
          notes: "Updated property notes",
          accountable_attributes: {
            id: @account.accountable.id,
            subtype: "condominium"
          }
        }
      }
    end

    @account.reload
    assert_equal "Updated Property", @account.name
    assert_equal "condominium", @account.subtype
    assert_equal "Updated Lender", @account[:institution_name]
    assert_equal "updatedlender.example", @account[:institution_domain]
    assert_equal "Updated property notes", @account[:notes]

    # If account is active, it renders edit view; otherwise redirects to balances
    if @account.active?
      assert_response :success
    else
      assert_redirected_to balances_property_path(@account)
    end
  end

  test "editing the living area marks it as user-set, so valuation refreshes send it" do
    property = @account.accountable
    assert_not property.user_set_area?

    patch property_path(@account), params: {
      account: { accountable_attributes: { id: property.id, area_value: 1364, area_unit: "sqft" } }
    }

    property.reload
    assert_equal 1364, property.area_value
    assert property.locked?(:area_value)
    assert property.user_set_area?
  end

  # Tab view tests
  test "shows balances tab" do
    get balances_property_path(@account)
    assert_response :success
  end

  test "shows address tab" do
    get address_property_path(@account)
    assert_response :success
  end

  # Tab update tests
  test "updates balances tab" do
    original_balance = @account.balance

    patch update_balances_property_path(@account), params: {
      account: {
        balance: 600000,
        currency: "EUR"
      }
    }

    @account.reload
    assert_equal 600000, @account.balance
    assert_equal "EUR", @account.currency

    # If account is active, it renders balances view; otherwise redirects to address
    if @account.active?
      assert_response :success
    else
      assert_redirected_to address_property_path(@account)
    end
  end

  test "updates address tab" do
    patch update_address_property_path(@account), params: {
      property: {
        address_attributes: {
          line1: "456 New Street",
          locality: "San Francisco",
          region: "CA",
          country: "US",
          postal_code: "94102"
        }
      }
    }

    @account.reload
    assert_equal "456 New Street", @account.accountable.address.line1
    assert_equal "San Francisco", @account.accountable.address.locality

    # If account is draft, it activates and redirects; otherwise renders address
    if @account.draft?
      assert_redirected_to account_path(@account)
    else
      assert_response :success
    end
  end

  test "balances update handles validation errors" do
    Account.any_instance.stubs(:set_current_balance).returns(OpenStruct.new(success?: false, error_message: "Invalid balance"))

    patch update_balances_property_path(@account), params: {
      account: {
        balance: 600000,
        currency: "EUR"
      }
    }

    assert_response :unprocessable_entity
  end

  test "address update handles validation errors" do
    Property.any_instance.stubs(:update).returns(false)

    patch update_address_property_path(@account), params: {
      property: {
        address_attributes: {
          line1: "123 Test St"
        }
      }
    }

    assert_response :unprocessable_entity
  end

  test "address update activates draft account" do
    # Create a draft property account
    draft_account = Account.create!(
      family: @user.family,
      name: "Draft Property",
      accountable: Property.new,
      status: "draft",
      balance: 500000,
      currency: "USD"
    )

    assert draft_account.draft?

    patch update_address_property_path(draft_account), params: {
      property: {
        address_attributes: {
          line1: "789 Activate St",
          locality: "New York",
          region: "NY",
          country: "US",
          postal_code: "10001"
        }
      }
    }

    draft_account.reload
    assert draft_account.active?
    assert_redirected_to account_path(draft_account)
  end

  test "address update on draft account honors stored return_to over the account page" do
    draft_account = Account.create!(
      family: @user.family,
      name: "Draft Property RT",
      accountable: Property.new,
      status: "draft",
      balance: 500000,
      currency: "USD"
    )

    # The property wizard (create → balances → address) doesn't thread return_to
    # as a form param, so StoreLocation's session value is the only carrier.
    get new_account_path(return_to: transactions_path)

    patch update_address_property_path(draft_account), params: {
      property: {
        address_attributes: {
          line1: "789 Activate St",
          locality: "New York",
          region: "NY",
          country: "US",
          postal_code: "10001"
        }
      }
    }

    draft_account.reload
    assert draft_account.active?
    assert_redirected_to transactions_path
  end

  test "address update ignores an external stored return_to (open-redirect guard)" do
    draft_account = Account.create!(
      family: @user.family,
      name: "Draft Property Evil",
      accountable: Property.new,
      status: "draft",
      balance: 500000,
      currency: "USD"
    )

    # A hostile ?return_to is rejected at store time, so the wizard falls back
    # to the account page rather than stream-redirecting off-site.
    get new_account_path(return_to: "https://evil.example/phish")

    patch update_address_property_path(draft_account), params: {
      property: {
        address_attributes: {
          line1: "1 Safe St", locality: "NYC", region: "NY", country: "US", postal_code: "10001"
        }
      }
    }

    draft_account.reload
    assert draft_account.active?
    assert_redirected_to account_path(draft_account)
  end

  test "address update tolerates a non-String stored return_to without raising" do
    draft_account = Account.create!(
      family: @user.family,
      name: "Draft Property Array",
      accountable: Property.new,
      status: "draft",
      balance: 500000,
      currency: "USD"
    )

    # `?return_to[]=foo` makes params[:return_to] an Array; safe_return_to must
    # reject it via the is_a?(String) guard instead of raising NoMethodError.
    get new_account_path("return_to" => [ "/transactions" ])

    patch update_address_property_path(draft_account), params: {
      property: {
        address_attributes: {
          line1: "1 Safe St", locality: "NYC", region: "NY", country: "US", postal_code: "10001"
        }
      }
    }

    draft_account.reload
    assert draft_account.active?
    assert_redirected_to account_path(draft_account)
  end

  # AVM provider lookup tests
  def stub_avm_provider(response)
    provider = mock
    provider.stubs(:fetch_property_valuation).returns(response)
    Provider::Registry.stubs(:rentcast).returns(provider)
    provider
  end

  def successful_avm_response
    Provider::Response.new(
      success?: true,
      data: Provider::PropertyValuationConcept::PropertyValuation.new(
        valuation: 356_000,
        currency: "USD",
        property_type: "single_family_home",
        year_built: 1973,
        area_value: 1878,
        area_unit: "sqft"
      ),
      error: nil
    )
  end

  test "new shows method selector when an AVM provider is configured" do
    stub_avm_provider(successful_avm_response)

    get new_property_path(step: "method_select")

    assert_response :success
    assert_match "Add via RentCast", response.body
  end

  test "new skips method selector when no AVM provider is configured" do
    Provider::Registry.stubs(:rentcast).returns(nil)
    Provider::Registry.stubs(:realie).returns(nil)

    get new_property_path(step: "method_select")

    assert_response :success
    assert_match "Enter property manually", response.body
  end

  test "new renders AVM lookup form for a configured provider" do
    stub_avm_provider(successful_avm_response)

    get new_property_path(method: "rentcast")

    assert_response :success
    assert_match "Add property via RentCast", response.body
  end

  test "AVM lookup renders a preview without creating an account" do
    provider = mock
    provider.expects(:fetch_property_valuation).with(
      line1: "5500 Grand Lake Dr",
      locality: "San Antonio",
      region: "TX",
      postal_code: "78244"
    ).returns(successful_avm_response)
    Provider::Registry.stubs(:rentcast).returns(provider)

    assert_no_difference "Account.count" do
      post properties_path, params: {
        avm_provider: "rentcast",
        account: {
          name: "AVM Home",
          accountable_type: "Property",
          address: {
            line1: "5500 Grand Lake Dr",
            locality: "San Antonio",
            region: "TX",
            postal_code: "78244"
          }
        }
      }
    end

    assert_response :success
    assert_match "Confirm property details", response.body
    assert_match "1973", response.body
    assert_match "1878", response.body
  end

  test "AVM preview warns when no property record was found" do
    no_record = Provider::Response.new(
      success?: true,
      data: Provider::PropertyValuationConcept::PropertyValuation.new(
        valuation: 450_000, currency: "USD", property_type: nil, year_built: nil, area_value: nil, area_unit: "sqft"
      ),
      error: nil
    )
    stub_avm_provider(no_record)

    post properties_path, params: {
      avm_provider: "rentcast",
      account: {
        name: "AVM Home",
        accountable_type: "Property",
        address: { line1: "1 Ghost St", locality: "San Antonio", region: "TX", postal_code: "78244" }
      }
    }

    assert_response :success
    assert_match "couldn&#39;t find a property record", response.body
    assert_match "Unknown", response.body
  end

  def signed_preview_token(family: @user.family)
    Rails.application.message_verifier(:avm_preview).generate(
      {
        "provider_key" => "rentcast",
        "name" => "AVM Home",
        "address" => {
          "line1" => "5500 Grand Lake Dr",
          "locality" => "San Antonio",
          "region" => "TX",
          "postal_code" => "78244"
        },
        "data" => {
          "valuation" => "356000.0",
          "currency" => "USD",
          "property_type" => "single_family_home",
          "year_built" => "1973",
          "area_value" => "1878",
          "area_unit" => "sqft"
        }
      },
      expires_in: 1.hour,
      purpose: "avm_preview/family/#{family.id}"
    )
  end

  test "AVM confirm creates the account from the signed preview token without a provider call" do
    provider = mock
    provider.expects(:fetch_property_valuation).never
    Provider::Registry.stubs(:rentcast).returns(provider)

    assert_difference -> { Account.count } => 1 do
      post properties_path, params: {
        avm_provider: "rentcast",
        avm_step: "confirm",
        avm_preview_token: signed_preview_token,
        account: { accountable_type: "Property" }
      }
    end

    created_account = Account.order(:created_at).last
    assert_redirected_to account_path(created_account)
    assert created_account.active?
    assert_equal "AVM Home", created_account.name
    assert_equal 356_000, created_account.balance
    assert_equal "USD", created_account.currency

    property = created_account.accountable
    assert_equal "rentcast", property.avm_provider
    assert_equal Date.current, property.avm_last_synced_on
    assert_equal "single_family_home", property.subtype
    assert_equal 1973, property.year_built
    assert_equal 1878, property.area_value
    assert_equal "sqft", property.area_unit

    address = property.address
    assert_equal "5500 Grand Lake Dr", address.line1
    assert_equal "San Antonio", address.locality
    assert_equal "TX", address.region
    assert_equal "78244", address.postal_code
    assert_equal "US", address.country
  end

  test "re-renders lookup form when the AVM provider returns an error" do
    stub_avm_provider(
      Provider::Response.new(
        success?: false,
        data: nil,
        error: Provider::Rentcast::Error.new("RentCast could not find a property matching this address")
      )
    )

    assert_no_difference "Account.count" do
      post properties_path, params: {
        avm_provider: "rentcast",
        account: {
          name: "AVM Home",
          accountable_type: "Property",
          address: { line1: "1 Nowhere Ln", locality: "Nowhere", region: "TX", postal_code: "00000" }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match "could not find a property", response.body
  end

  test "rejects AVM confirm without a valid signed preview token" do
    provider = mock
    provider.expects(:fetch_property_valuation).never
    Provider::Registry.stubs(:rentcast).returns(provider)

    assert_no_difference "Account.count" do
      post properties_path, params: {
        avm_provider: "rentcast",
        avm_step: "confirm",
        avm_preview_token: "forged-token",
        account: { accountable_type: "Property" }
      }
    end

    assert_response :unprocessable_entity
    assert_match "preview has expired", response.body
  end

  test "rejects an AVM preview token minted for another family" do
    provider = mock
    provider.expects(:fetch_property_valuation).never
    Provider::Registry.stubs(:rentcast).returns(provider)

    assert_no_difference "Account.count" do
      post properties_path, params: {
        avm_provider: "rentcast",
        avm_step: "confirm",
        avm_preview_token: signed_preview_token(family: families(:empty)),
        account: { accountable_type: "Property" }
      }
    end

    assert_response :unprocessable_entity
    assert_match "preview has expired", response.body
  end

  test "rejects incomplete AVM submissions before calling the provider" do
    provider = mock
    provider.expects(:fetch_property_valuation).never
    Provider::Registry.stubs(:rentcast).returns(provider)

    assert_no_difference "Account.count" do
      post properties_path, params: {
        avm_provider: "rentcast",
        account: {
          name: "",
          accountable_type: "Property",
          address: { line1: "5500 Grand Lake Dr", locality: "", region: "TX", postal_code: "78244" }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match "complete US address", response.body
  end

  test "rejects AVM creation for unconfigured providers" do
    assert_no_difference "Account.count" do
      post properties_path, params: {
        avm_provider: "realie",
        account: {
          name: "AVM Home",
          accountable_type: "Property",
          address: { line1: "123 Main Street", locality: "LA", region: "CA", postal_code: "90001" }
        }
      }
    end

    assert_redirected_to new_property_path
  end

  test "edit form leaves out the icon picker, which property updates do not save" do
    get edit_property_url(@account)

    assert_response :success
    assert_select "[data-controller=account-logo-picker]", 0
    assert_select "form##{dom_id(@account, :logo_options)}", 0
  end

  # Chimnie (UK, UPRN-based) lookups

  def chimnie_avm_response
    Provider::Response.new(
      success?: true,
      data: Provider::PropertyValuationConcept::PropertyValuation.new(
        valuation: 425_000,
        currency: "GBP",
        property_type: nil,
        year_built: nil,
        area_value: nil,
        area_unit: "sqft",
        external_id: "999000000001",
        valuation_low: 340_000,
        valuation_high: 530_000,
        confidence: "high"
      ),
      error: nil
    )
  end

  def chimnie_lookup_params(uprn: "999000000001")
    {
      avm_provider: "chimnie",
      account: {
        name: "Chester Flat",
        accountable_type: "Property",
        address: { line1: "1 High Street", locality: "Chester", region: "", postal_code: "CH1 1MN" },
        property: { avm_external_id: uprn }
      }
    }
  end

  test "Chimnie lookup form asks for a UPRN and a UK address" do
    Provider::Registry.stubs(:chimnie).returns(mock)

    get new_property_path(method: "chimnie")

    assert_response :success
    assert_match "Add property via Chimnie", response.body
    assert_select "input[name='account[property][avm_external_id]'][required]"
    assert_select "input[name='account[address][region]']:not([required])"
    assert_match "United Kingdom", response.body
  end

  test "Chimnie lookup previews the estimate range and confidence by UPRN" do
    provider = mock
    provider.expects(:fetch_property_valuation).with(
      line1: "1 High Street",
      locality: "Chester",
      region: "",
      postal_code: "CH1 1MN",
      external_id: "999000000001"
    ).returns(chimnie_avm_response)
    Provider::Registry.stubs(:chimnie).returns(provider)

    assert_no_difference "Account.count" do
      post properties_path, params: chimnie_lookup_params
    end

    assert_response :success
    assert_match "Confirm property details", response.body
    assert_match "999000000001", response.body
    assert_match "Estimate range", response.body
    assert_match "High", response.body
    assert_match "HM Land Registry", response.body
    assert_no_match "couldn&#39;t find a property record", response.body
  end

  test "Chimnie lookup requires a UPRN without spending a request" do
    provider = mock
    provider.expects(:fetch_property_valuation).never
    Provider::Registry.stubs(:chimnie).returns(provider)

    assert_no_difference "Account.count" do
      post properties_path, params: chimnie_lookup_params(uprn: "")
    end

    assert_response :unprocessable_entity
    assert_match "UPRN", response.body
  end

  test "Chimnie confirm creates a GBP property linked by UPRN" do
    provider = mock
    provider.expects(:fetch_property_valuation).once.returns(chimnie_avm_response)
    Provider::Registry.stubs(:chimnie).returns(provider)

    post properties_path, params: chimnie_lookup_params
    token = css_select("input[name='avm_preview_token']").first["value"]

    assert_difference -> { Account.count } => 1 do
      post properties_path, params: {
        avm_provider: "chimnie",
        avm_step: "confirm",
        avm_preview_token: token,
        account: { accountable_type: "Property" }
      }
    end

    account = Account.order(:created_at).last
    assert_equal "GBP", account.currency
    assert_equal 425_000, account.balance
    assert account.active?
    assert_equal "chimnie", account.property.avm_provider
    assert_equal "999000000001", account.property.avm_external_id
    assert_equal "GB", account.property.address.country
    assert_equal "GBP", account.entries.valuations.last.currency
    assert_equal "Chimnie valuation", account.entries.valuations.last.name
  end

  test "refresh_valuation queues a forced refresh of the property" do
    @account.property.update!(avm_provider: "chimnie", avm_external_id: "999000000001")
    Provider::Registry.stubs(:chimnie).returns(mock)

    assert_enqueued_with(job: SyncPropertyValuationsJob, args: [ { property_id: @account.property.id, force: true } ]) do
      post refresh_valuation_property_path(@account)
    end

    assert_redirected_to account_path(@account)
  end

  test "refresh_valuation does nothing for properties without a provider" do
    @account.property.update!(avm_provider: nil)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post refresh_valuation_property_path(@account)
    end

    assert_redirected_to account_path(@account)
  end

  test "refresh_valuation refuses when the provider is no longer configured" do
    @account.property.update!(avm_provider: "chimnie", avm_external_id: "999000000001")
    Provider::Registry.stubs(:chimnie).returns(nil)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post refresh_valuation_property_path(@account)
    end

    assert_redirected_to account_path(@account)
    assert_match "Chimnie isn't configured", flash[:alert]
  end

  test "method selector shows provider logos for valuation providers" do
    Provider::Registry.stubs(:chimnie).returns(mock)

    get new_property_path(step: "method_select")

    assert_response :success
    assert_select "a[href*='method=chimnie']", text: /CH\s+Add via Chimnie/
  end

  test "refresh_valuation is scoped to the current family" do
    @account.property.update!(avm_provider: "chimnie", avm_external_id: "999000000001")
    sign_in users(:empty)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post refresh_valuation_property_path(@account)
    end

    assert_response :not_found
  end

  test "overview offers a valuation refresh for provider-linked properties" do
    @account.property.update!(avm_provider: "chimnie", avm_external_id: "999000000001", avm_last_synced_on: Date.current)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "form[action='#{refresh_valuation_property_path(@account)}']"
  end

  test "link_valuation links a manual property after its first valuation succeeds" do
    @account.property.update!(avm_provider: nil, avm_last_synced_on: 1.year.ago.to_date)
    @account.property.address.update!(country: "United States")
    Provider::Registry.stubs(:rentcast).returns(rentcast_provider_returning(Provider::Response.new(success?: true, data: valuation_data(612_000), error: nil)))

    post link_valuation_property_path(@account, avm_provider: "rentcast")

    assert_redirected_to account_path(@account)
    assert_equal "Linked to RentCast and updated the property's value.", flash[:notice]
    assert_equal "rentcast", @account.property.reload.avm_provider
    assert_equal Date.current, @account.property.avm_last_synced_on
    assert_equal 612_000, @account.reload.balance
  end

  test "link_valuation keeps the property unlinked when the first valuation fails" do
    @account.property.update!(avm_provider: nil)
    error = Provider::Rentcast::Error.new("No property found")
    Provider::Registry.stubs(:rentcast).returns(rentcast_provider_returning(Provider::Response.new(success?: false, data: nil, error: error)))

    post link_valuation_property_path(@account, avm_provider: "rentcast")

    assert_redirected_to account_path(@account)
    assert_equal "RentCast couldn't value this property, so it wasn't linked. Check that the address is correct, then try again.", flash[:alert]
    assert_nil @account.property.reload.avm_provider
    assert_equal 550_000, @account.reload.balance
  end

  test "link_valuation keeps the property unlinked when the provider budget is spent" do
    @account.property.update!(avm_provider: nil)
    provider = mock
    provider.stubs(:requests_remaining?).returns(false)
    provider.expects(:fetch_property_valuation).never
    Provider::Registry.stubs(:rentcast).returns(provider)

    post link_valuation_property_path(@account, avm_provider: "rentcast")

    assert_nil @account.property.reload.avm_provider
    assert flash[:alert].present?
  end

  test "link_valuation refuses an unconfigured provider" do
    @account.property.update!(avm_provider: nil)
    Provider::Registry.stubs(:rentcast).returns(nil)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post link_valuation_property_path(@account, avm_provider: "rentcast")
    end

    assert_redirected_to account_path(@account)
    assert_nil @account.property.reload.avm_provider
  end

  test "link_valuation refuses providers that need a property identifier" do
    @account.property.update!(avm_provider: nil)
    Provider::Registry.stubs(:chimnie).returns(mock)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post link_valuation_property_path(@account, avm_provider: "chimnie")
    end

    assert_nil @account.property.reload.avm_provider
  end

  test "link_valuation refuses addresses outside the provider's country" do
    @account.property.update!(avm_provider: nil)
    @account.property.address.update!(country: "Canada")
    Provider::Registry.stubs(:rentcast).returns(mock)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post link_valuation_property_path(@account, avm_provider: "rentcast")
    end

    assert_nil @account.property.reload.avm_provider
  end

  test "link_valuation requires a known country" do
    @account.property.update!(avm_provider: nil)
    @account.property.address.update!(country: "")
    Provider::Registry.stubs(:rentcast).returns(mock)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post link_valuation_property_path(@account, avm_provider: "rentcast")
    end

    assert_nil @account.property.reload.avm_provider
  end

  test "link_valuation does not replace an existing provider" do
    @account.property.update!(avm_provider: "realie")
    Provider::Registry.stubs(:rentcast).returns(mock)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post link_valuation_property_path(@account, avm_provider: "rentcast")
    end

    assert_equal "realie", @account.property.reload.avm_provider
  end

  test "link_valuation is scoped to the current family" do
    @account.property.update!(avm_provider: nil)
    Provider::Registry.stubs(:rentcast).returns(mock)
    sign_in users(:empty)

    assert_no_enqueued_jobs(only: SyncPropertyValuationsJob) do
      post link_valuation_property_path(@account, avm_provider: "rentcast")
    end

    assert_response :not_found
    assert_nil @account.property.reload.avm_provider
  end

  test "overview offers linking a manual property to a configured provider" do
    @account.property.update!(avm_provider: nil)
    Provider::Registry.stubs(:rentcast).returns(mock)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "form[action='#{link_valuation_property_path(@account, avm_provider: "rentcast")}']"
    assert_select "form[action*='avm_provider=chimnie']", count: 0
  end

  test "overview shows the trend in the family currency for a foreign-currency property" do
    purchase_date = 2.years.ago.to_date
    foreign_property_with_value(purchase_date: purchase_date)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: purchase_date, rate: 1.0)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.9)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "[data-testid='family-currency-trend']" do
      assert_select "h4", text: "Trend in EUR"
      assert_select "span", text: /-€1,000/
      assert_select "span", text: "(-1.0%)"
    end
  end

  test "overview shows an infinite family-currency trend from a zero purchase value" do
    purchase_date = 2.years.ago.to_date
    foreign_property_with_value(purchase_date: purchase_date, purchase_amount: 0)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: purchase_date, rate: 1.0)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.9)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "[data-testid='family-currency-trend']" do
      assert_select "span", text: "(＋∞)"
      assert_select "span", text: /Infinity|NaN/, count: 0
    end
  end

  test "overview says the rate is unavailable instead of guessing a family-currency trend" do
    foreign_property_with_value(purchase_date: 2.years.ago.to_date)
    ExchangeRate.stubs(:provider).returns(nil)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "[data-testid='family-currency-trend']", text: /Exchange rate unavailable/
    assert_select "[data-testid='family-currency-trend']", text: /€/, count: 0
  end

  test "updates the property's cost tag" do
    tag = @account.family.tags.create!(name: "Land costs")

    patch property_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable.id, cost_tag_id: tag.id } }
    }

    assert_response :success
    assert_equal tag.id, @account.property.reload.cost_tag_id
  end

  test "rejects a cost tag from another family" do
    other_tag = families(:empty).tags.create!(name: "Not ours")

    patch property_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable.id, cost_tag_id: other_tag.id } }
    }

    assert_response :unprocessable_entity
    assert_nil @account.property.reload.cost_tag_id
  end

  test "rejects a cost tag that no longer exists" do
    tag = @account.family.tags.create!(name: "Land costs")
    tag.destroy!

    patch property_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable.id, cost_tag_id: tag.id } }
    }

    assert_response :unprocessable_entity
    assert_nil @account.property.reload.cost_tag_id
  end

  test "edit form offers the family's tags as the cost tag" do
    get edit_property_path(@account)

    assert_response :success
    assert_select "input[name='account[accountable_attributes][cost_tag_id]']"
    assert_select "[role='option']", text: tags(:one).name
  end

  test "overview shows the purchase costs, cost basis and gain after costs" do
    tag = cost_tagged_property
    create_cost(accounts(:depository), 8_000, tag)
    create_cost(accounts(:credit_card), 2_000, tag)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "[data-testid='purchase-costs']" do
      assert_select "h4", text: "Purchase costs"
      assert_select "*", text: /\$10,000/
      assert_select "a[href*='tags']", text: "2 transactions tagged Land costs"
      # Costs in closed accounts count too, so the list it opens includes them.
      assert_select "a[href*='active_accounts_only%5D=false']"
      # Outside the blurred value, so privacy mode leaves the link clickable.
      assert_select ".privacy-sensitive a", count: 0
      assert_select ".privacy-sensitive", text: /\$10,000/
      assert_select "*", text: /\$510,000/
      assert_select "span", text: /\$40,000/
      assert_select "span", text: "(7.8%)"
    end
  end

  test "the cost link leaves out transfers, pending transactions and accounts the viewer can't see" do
    tag = cost_tagged_property
    create_cost(accounts(:depository), 8_000, tag)
    create_cost(accounts(:credit_card), 2_000, tag)
    # A tagged transfer is not a cost.
    accounts(:depository).entries.create!(
      date: 1.year.ago.to_date, name: "To savings", amount: 5_000, currency: "USD",
      entryable: Transaction.new(tags: [ tag ], kind: "funds_movement")
    )
    # Pending at the bank, so not counted yet.
    accounts(:depository).entries.create!(
      date: 1.year.ago.to_date, name: "Pending deposit", amount: 1_000, currency: "USD",
      entryable: Transaction.new(tags: [ tag ], extra: { "simplefin" => { "pending" => true } })
    )
    # Not shared with the member.
    create_cost(accounts(:investment), 3_000, tag)
    AccountShare.create!(account: @account, user: users(:family_member), permission: "read_only")
    sign_in users(:family_member)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "[data-testid='purchase-costs']" do
      assert_select "*", text: /\$10,000/
      assert_select "a[href*='tags']", text: "2 transactions tagged Land costs"
    end

    # The list the link opens leaves the transfer and the pending one out too.
    get css_select("[data-testid='purchase-costs'] a[href*='tags']").first["href"]
    assert_response :success
    assert_includes response.body, "Notary"
    assert_not_includes response.body, "To savings"
    assert_not_includes response.body, "Pending deposit"
  end

  test "overview says the rate is unavailable for a cost without a stored rate" do
    tag = cost_tagged_property
    eur_account = @account.family.accounts.create!(name: "Euro bank", balance: 0, currency: "EUR", owner: @user, accountable: Depository.new)
    create_cost(eur_account, 1_000, tag, currency: "EUR")
    ExchangeRate.stubs(:provider).returns(nil)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "[data-testid='purchase-costs']", text: /Exchange rate unavailable/
    assert_select "[data-testid='purchase-costs'] h4", text: "Gain after costs"
  end

  test "overview shows the costs of a foreign-currency property in the family currency" do
    purchase_date = 1.year.ago.to_date
    tag = cost_tagged_property
    @account.family.update!(currency: "EUR")
    eur_account = @account.family.accounts.create!(name: "Euro bank", balance: 0, currency: "EUR", owner: @user, accountable: Depository.new)
    pyg_account = @account.family.accounts.create!(name: "Guarani bank", balance: 0, currency: "PYG", owner: @user, accountable: Depository.new)
    create_cost(eur_account, 9_000, tag, currency: "EUR")
    create_cost(pyg_account, 8_000_000, tag, currency: "PYG")
    # The pairs sync stores: each account's currency into the family's, and the inverse.
    [ [ "USD", purchase_date, 1.0 ], [ "USD", Date.current, 0.9 ], [ "PYG", purchase_date, 0.000125 ] ].each do |currency, date, rate|
      ExchangeRate.create!(from_currency: currency, to_currency: "EUR", date: date, rate: rate)
      ExchangeRate.create!(from_currency: "EUR", to_currency: currency, date: date, rate: 1 / rate.to_d)
    end
    ExchangeRate.stubs(:provider).returns(nil)

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "[data-testid='purchase-costs']" do
      assert_select "h4", text: "Purchase costs in EUR"
      assert_select "h4", text: "Cost basis in EUR"
      assert_select "h4", text: "Gain after costs in EUR"
      assert_select "*", text: /€10[.,]000/
      assert_select "*", text: /€510[.,]000/
      assert_select "span", text: /-€15[.,]000/
      assert_select "*", text: /Exchange rate unavailable/, count: 0
    end
  end

  test "overview has no purchase costs without a cost tag" do
    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "[data-testid='purchase-costs']", count: 0
  end

  test "overview has no family-currency trend when the property is in the family currency" do
    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "[data-testid='family-currency-trend']", count: 0
  end

  private
    def cost_tagged_property
      tag = @account.family.tags.create!(name: "Land costs")
      @account.property.update!(cost_tag: tag)
      @account.entries.valuations.destroy_all
      @account.entries.create!(
        date: 1.year.ago.to_date, name: "Original purchase price", amount: 500_000, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      @account.update!(balance: 550_000)
      tag
    end

    def create_cost(account, amount, tag, currency: "USD")
      account.entries.create!(
        date: 1.year.ago.to_date, name: "Notary", amount: amount, currency: currency,
        entryable: Transaction.new(tags: [ tag ])
      )
    end

    def foreign_property_with_value(purchase_date:, purchase_amount: 100_000)
      @account.family.update!(currency: "EUR")
      @account.entries.valuations.destroy_all
      @account.entries.create!(
        date: purchase_date, name: "Original purchase price", amount: purchase_amount, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      @account.update!(balance: 110_000)
    end

    def valuation_data(valuation)
      Provider::PropertyValuationConcept::PropertyValuation.new(
        valuation: valuation, currency: "USD", property_type: "single_family_home",
        year_built: 2002, area_value: 1000, area_unit: "sqft"
      )
    end

    def rentcast_provider_returning(response)
      provider = mock
      provider.stubs(:requests_remaining?).returns(true)
      provider.stubs(:valuation_currency).returns("USD")
      provider.stubs(:fetch_property_valuation).returns(response)
      provider
    end
end
