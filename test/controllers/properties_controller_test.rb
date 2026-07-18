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

  test "creates active property from AVM provider lookup" do
    stub_avm_provider(successful_avm_response)

    assert_difference -> { Account.count } => 1 do
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
end
