require "test_helper"

class VehiclesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:vehicle)
  end

  test "creates with vehicle details" do
    assert_difference -> { Account.count } => 1,
      -> { Vehicle.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post vehicles_path, params: {
        account: {
          name: "Vehicle",
          balance: 30000,
          currency: "USD",
          institution_name: "Auto Lender",
          institution_domain: "autolender.example",
          notes: "Lease notes",
          accountable_type: "Vehicle",
          accountable_attributes: {
            make: "Toyota",
            model: "Camry",
            year: 2020,
            mileage_value: 15000,
            mileage_unit: "mi"
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "Vehicle", created_account.name
    assert_equal 30000, created_account.balance
    assert_equal "USD", created_account.currency
    assert_equal "Auto Lender", created_account[:institution_name]
    assert_equal "autolender.example", created_account[:institution_domain]
    assert_equal "Lease notes", created_account[:notes]
    assert_equal "Toyota", created_account.accountable.make
    assert_equal "Camry", created_account.accountable.model
    assert_equal 2020, created_account.accountable.year
    assert_equal 15000, created_account.accountable.mileage_value
    assert_equal "mi", created_account.accountable.mileage_unit

    assert_redirected_to created_account
    assert_equal "Vehicle account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with vehicle details" do
    assert_no_difference [ "Account.count", "Vehicle.count" ] do
      patch vehicle_path(@account), params: {
        account: {
          name: "Updated Vehicle",
          balance: 28000,
          currency: "USD",
          institution_name: "Updated Lender",
          institution_domain: "updatedlender.example",
          notes: "Updated lease notes",
          accountable_type: "Vehicle",
          accountable_attributes: {
            id: @account.accountable_id,
            make: "Honda",
            model: "Accord",
            year: 2021,
            mileage_value: 20000,
            mileage_unit: "mi",
            purchase_price: 32000
          }
        }
      }
    end

    @account.reload
    assert_equal "Updated Vehicle", @account.name
    assert_equal 28000, @account.balance
    assert_equal "Updated Lender", @account[:institution_name]
    assert_equal "updatedlender.example", @account[:institution_domain]
    assert_equal "Updated lease notes", @account[:notes]

    assert_redirected_to account_path(@account)
    assert_equal "Vehicle account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end
end
