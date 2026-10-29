require "test_helper"

class VehiclesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest, EntriesTestHelper

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
            initial_balance: 32000,
            purchase_date: 3.years.ago.to_date
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
    assert_equal 32000, @account.opening_anchor_balance
    assert_equal 3.years.ago.to_date, @account.opening_anchor_date

    assert_redirected_to account_path(@account)
    assert_equal "Vehicle account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "creates with a purchase price below the current value" do
    post vehicles_path, params: {
      account: {
        name: "Vehicle",
        balance: 30000,
        currency: "USD",
        opening_balance_date: 1.year.ago.to_date,
        accountable_type: "Vehicle",
        accountable_attributes: { make: "Toyota", initial_balance: 35000 }
      }
    }

    account = Account.order(:created_at).last
    assert_equal 30000, account.balance
    assert_equal 35000, account.opening_anchor_balance
    assert_equal 1.year.ago.to_date, account.opening_anchor_date
    assert_equal 30000, account.valuations.reconciliation.first.entry.amount
    assert_equal Money.new(35000, "USD"), account.vehicle.purchase_price
    assert_empty account.vehicle.locked_attributes.keys & %w[initial_balance purchase_date]
  end

  test "edit form shows the purchase price and date" do
    @account.set_opening_anchor_balance(balance: 21000, date: 2.years.ago.to_date)

    get edit_vehicle_path(@account)

    assert_response :success
    assert_select "input[name='account[accountable_attributes][initial_balance]'][value='21000.00']"
    assert_select "input[name='account[accountable_attributes][purchase_date]'][value='#{2.years.ago.to_date}']"
    assert_select "input[type=hidden][name='account[accountable_attributes][initial_balance_shown]'][value='21000.0']"
  end

  test "updates the purchase price without touching the purchase date" do
    @account.set_opening_anchor_balance(balance: 0, date: 2.years.ago.to_date)

    patch vehicle_path(@account), params: {
      account: {
        accountable_attributes: { id: @account.accountable_id, initial_balance: 21000, purchase_date: "" }
      }
    }

    assert_redirected_to account_path(@account)
    assert_equal 21000, @account.reload.opening_anchor_balance
    assert_equal 2.years.ago.to_date, @account.opening_anchor_date
  end

  test "keeps the current value when only the purchase price changes" do
    @account.set_opening_anchor_balance(balance: 18000, date: 2.years.ago.to_date)

    patch vehicle_path(@account), params: {
      account: {
        accountable_attributes: { id: @account.accountable_id, initial_balance: 25000, purchase_date: 2.years.ago.to_date }
      }
    }

    assert_redirected_to account_path(@account)
    @account.reload
    assert_equal 25000, @account.opening_anchor_balance
    assert_equal 18000, @account.balance
    reconciliation = @account.valuations.reconciliation.first.entry
    assert_equal [ Date.current, 18000 ], [ reconciliation.date, reconciliation.amount ]
  end

  test "a future valuation does not stop the current value being kept" do
    @account.set_opening_anchor_balance(balance: 18000, date: 2.years.ago.to_date)
    create_valuation(account: @account, date: 1.month.from_now.to_date, amount: 15000)

    patch vehicle_path(@account), params: {
      account: {
        accountable_attributes: { id: @account.accountable_id, initial_balance: 25000, purchase_date: 2.years.ago.to_date }
      }
    }

    assert_redirected_to account_path(@account)
    today = @account.reload.entries.valuations.find_by(date: Date.current)
    assert_equal 18000, today&.amount
  end

  test "moving only the purchase date keeps the anchor's balance when a valuation predates it" do
    @account.set_opening_anchor_balance(balance: 21000, date: 1.year.ago.to_date)
    create_valuation(account: @account, date: 2.years.ago.to_date, amount: 22000)

    patch vehicle_path(@account), params: {
      account: {
        accountable_attributes: { id: @account.accountable_id, initial_balance: "22000.00", purchase_date: 3.years.ago.to_date }
      }
    }

    assert_redirected_to account_path(@account)
    assert_equal 21000, @account.reload.opening_anchor_balance
    assert_equal 3.years.ago.to_date, @account.opening_anchor_date
  end

  test "an edit that resubmits the prefilled purchase fields changes nothing" do
    @account.set_opening_anchor_balance(balance: 21000, date: 2.years.ago.to_date)
    clear_enqueued_jobs

    assert_no_difference "Entry.count" do
      patch vehicle_path(@account), params: {
        account: {
          name: "Renamed",
          accountable_attributes: { id: @account.accountable_id, initial_balance: "21000.00", purchase_date: 2.years.ago.to_date }
        }
      }
    end

    assert_redirected_to account_path(@account)
    assert_equal "Renamed", @account.reload.name
    assert_no_enqueued_jobs only: SyncJob
  end

  test "an edit of a vehicle without an opening anchor does not invent one" do
    assert_not @account.has_opening_anchor?

    get edit_vehicle_path(@account)
    assert_select "input[name='account[accountable_attributes][initial_balance]'][value='18000.00']"

    assert_no_difference "Entry.count" do
      patch vehicle_path(@account), params: {
        account: {
          name: "Renamed",
          accountable_attributes: { id: @account.accountable_id, initial_balance: "18000.00", purchase_date: @account.opening_anchor_date }
        }
      }
    end

    assert_redirected_to account_path(@account)
    assert_equal "Renamed", @account.reload.name
  end

  test "moving the purchase date of a vehicle without an anchor keeps its purchase price" do
    create_valuation(account: @account, date: 1.year.ago.to_date, amount: 20000)

    patch vehicle_path(@account), params: {
      account: {
        accountable_attributes: { id: @account.accountable_id, initial_balance: "20000.00", purchase_date: 2.years.ago.to_date }
      }
    }

    assert_redirected_to account_path(@account)
    assert_equal 20000, @account.reload.opening_anchor_balance
    assert_equal 2.years.ago.to_date, @account.opening_anchor_date
    assert_equal Money.new(20000, "USD"), @account.vehicle.purchase_price
  end

  test "an unchanged purchase date is not revalidated against older entries" do
    @account.set_opening_anchor_balance(balance: 21000, date: 1.year.ago.to_date)
    create_valuation(account: @account, date: 2.years.ago.to_date, amount: 22000)

    patch vehicle_path(@account), params: {
      account: {
        name: "Renamed",
        accountable_attributes: { id: @account.accountable_id, purchase_date: 1.year.ago.to_date }
      }
    }

    assert_redirected_to account_path(@account)
    assert_equal "Renamed", @account.reload.name
  end

  test "rejects a purchase date that is not a date" do
    @account.set_opening_anchor_balance(balance: 21000, date: 2.years.ago.to_date)

    patch vehicle_path(@account), params: {
      account: {
        name: "Renamed",
        accountable_attributes: { id: @account.accountable_id, purchase_date: "not-a-date" }
      }
    }

    assert_response :unprocessable_entity
    assert_equal "Honda Accord", @account.reload.name
    assert_equal 2.years.ago.to_date, @account.opening_anchor_date
  end

  test "a balance-only edit keeps the new balance when the anchor is dated today" do
    @account.set_opening_anchor_balance(balance: 18000, date: Date.current)

    patch vehicle_path(@account), params: {
      account: {
        balance: 15000,
        accountable_attributes: {
          id: @account.accountable_id, initial_balance: "18000.00", initial_balance_shown: "18000.00", purchase_date: Date.current
        }
      }
    }

    assert_redirected_to account_path(@account)
    @account.reload
    assert_equal 15000, @account.balance
    assert_equal 15000, @account.opening_anchor_balance
  end

  test "leaves the opening anchor alone when the purchase fields are blank" do
    @account.set_opening_anchor_balance(balance: 21000, date: 2.years.ago.to_date)

    patch vehicle_path(@account), params: {
      account: {
        name: "Renamed",
        accountable_attributes: { id: @account.accountable_id, initial_balance: "", purchase_date: "" }
      }
    }

    assert_redirected_to account_path(@account)
    assert_equal "Renamed", @account.reload.name
    assert_equal 21000, @account.opening_anchor_balance
    assert_equal 2.years.ago.to_date, @account.opening_anchor_date
  end

  test "rejects a purchase date that is not before the oldest entry" do
    @account.set_opening_anchor_balance(balance: 21000, date: 2.years.ago.to_date)
    create_valuation(account: @account, date: 1.year.ago.to_date, amount: 19000)

    patch vehicle_path(@account), params: {
      account: {
        name: "Renamed",
        accountable_attributes: { id: @account.accountable_id, initial_balance: 25000, purchase_date: 6.months.ago.to_date }
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Purchase date must be before the account&#39;s oldest entry"
    assert_equal "Honda Accord", @account.reload.name
    assert_equal 21000, @account.opening_anchor_balance
    assert_equal 2.years.ago.to_date, @account.opening_anchor_date
  end
end
