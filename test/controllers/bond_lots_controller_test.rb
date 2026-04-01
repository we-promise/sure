require "test_helper"

class BondLotsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:bond)
  end

  test "creates a purchase lot and calculates maturity date" do
    purchase_date = Date.new(2026, 3, 1)

    assert_difference [ "BondLot.count", "Entry.count", "Transaction.count" ], 1 do
      assert_enqueued_jobs 1, only: SyncJob do
        post bond_lots_path, params: {
          account_id: @account.id,
          bond_lot: {
            purchased_on: purchase_date,
            amount: 2500,
            term_months: 4,
            interest_rate: 4.75,
            subtype: "other_bond",
            rate_type: "fixed",
            coupon_frequency: "at_maturity"
          }
        }
      end
    end

    lot = BondLot.order(:created_at).last
    assert_equal @account.bond, lot.bond
    assert_equal Date.new(2026, 7, 1), lot.maturity_date
    assert_not_nil lot.entry
    assert_equal purchase_date, lot.entry.date
    assert_equal 2500.to_d, lot.entry.amount
    assert_redirected_to account_path(@account)
  end

  test "removes a purchase lot" do
    lot = @account.bond.bond_lots.create!(
      purchased_on: Date.current,
      amount: 1000,
      term_months: 6,
      interest_rate: 4.0,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      entry: @account.entries.create!(
        date: Date.current,
        name: "Bond purchase",
        amount: 1000,
        currency: @account.currency,
        entryable: Transaction.new(kind: :funds_movement)
      )
    )

    assert_difference [ "BondLot.count", "Entry.count" ], -1 do
      assert_enqueued_jobs 1, only: SyncJob do
        delete bond_lot_path(lot)
      end
    end

    assert_redirected_to account_path(@account)
  end

  test "renders edit form for a purchase lot" do
    lot = @account.bond.bond_lots.create!(
      purchased_on: Date.new(2026, 1, 1),
      amount: 500,
      term_months: 6,
      interest_rate: 3.5,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    )

    get edit_bond_lot_path(lot)

    assert_response :success
  end

  test "renders drawer show for a purchase lot" do
    lot = @account.bond.bond_lots.create!(
      purchased_on: Date.new(2026, 1, 1),
      amount: 500,
      term_months: 6,
      interest_rate: 3.5,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    )

    get bond_lot_path(lot)

    assert_response :success
    assert_includes @response.body, "Delete"
  end

  test "updates a purchase lot and its entry" do
    entry_record = @account.entries.create!(
      date: Date.new(2026, 2, 1),
      name: "Bond purchase: Treasury Bill",
      amount: 1000,
      currency: @account.currency,
      entryable: Transaction.new(kind: :funds_movement, extra: {})
    )

    lot = @account.bond.bond_lots.create!(
      purchased_on: Date.new(2026, 2, 1),
      amount: 1000,
      term_months: 12,
      interest_rate: 4.0,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      entry: entry_record
    )

    assert_enqueued_jobs 1, only: SyncJob do
      patch bond_lot_path(lot), params: {
        bond_lot: {
          purchased_on: Date.new(2026, 2, 15),
          amount: 1200,
          issue_date: Date.new(2026, 2, 1),
          units: 12,
          nominal_per_unit: 100,
          interest_rate: 4.5,
          subtype: "rod",
          rate_type: "variable",
          coupon_frequency: "at_maturity",
          first_period_rate: 6.0,
          inflation_margin: 1.5,
          inflation_rate_assumption: 4.0,
          cpi_lag_months: 2
        }
      }
    end

    assert_redirected_to account_path(@account)

    lot.reload
    assert_equal 1200.to_d, lot.amount
    assert_equal 4.5.to_d, lot.interest_rate
    assert_equal "rod", lot.subtype
    assert_equal "at_maturity", lot.coupon_frequency
    assert_equal Date.new(2026, 2, 15), lot.purchased_on

    entry_record.reload
    assert_equal Date.new(2026, 2, 15), entry_record.date
    assert_equal 1200.to_d, entry_record.amount
  end

  test "update returns unprocessable entity for invalid params" do
    lot = @account.bond.bond_lots.create!(
      purchased_on: Date.new(2026, 1, 1),
      amount: 500,
      term_months: 6,
      interest_rate: 3.5,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    )

    patch bond_lot_path(lot), params: {
      bond_lot: { amount: -1 }
    }

    assert_response :unprocessable_entity
  end

  test "update returns drawer show on invalid params for drawer frame requests" do
    lot = @account.bond.bond_lots.create!(
      purchased_on: Date.new(2026, 1, 1),
      amount: 500,
      term_months: 6,
      interest_rate: 3.5,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    )

    patch bond_lot_path(lot),
          params: { bond_lot: { amount: -1 } },
          headers: { "Turbo-Frame" => "drawer" }

    assert_response :unprocessable_entity
    assert_select "turbo-frame#drawer"
  end

  test "creates EOD purchase without term months input" do
    purchase_date = Date.new(2026, 4, 1)

    assert_difference [ "BondLot.count", "Entry.count", "Transaction.count" ], 1 do
      assert_enqueued_jobs 1, only: SyncJob do
        post bond_lots_path, params: {
          account_id: @account.id,
          bond_lot: {
            purchased_on: purchase_date,
            issue_date: purchase_date,
            amount: 1000,
            units: 10,
            nominal_per_unit: 100,
            subtype: "eod",
            rate_type: "variable",
            coupon_frequency: "at_maturity",
            first_period_rate: 6.5,
            inflation_margin: 1.5,
            inflation_rate_assumption: 4.0,
            cpi_lag_months: 2
          }
        }
      end
    end

    lot = BondLot.order(:created_at).last
    assert_equal 120, lot.term_months
    assert_equal Date.new(2036, 4, 1), lot.maturity_date
    assert_redirected_to account_path(@account)
  end
end
