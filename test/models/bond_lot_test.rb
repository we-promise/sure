require "test_helper"

class BondLotTest < ActiveSupport::TestCase
  test "auto-assigns maturity date from purchase date and term" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2026, 1, 15),
      term_months: 3,
      amount: 1000,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      maturity_date: nil
    )

    lot.valid?

    assert_equal Date.new(2026, 4, 15), lot.maturity_date
  end

  test "requires positive principal and term" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      term_months: 0,
      amount: 0,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    )

    assert_not lot.valid?
    assert_includes lot.errors[:amount], "must be greater than 0"
    assert_includes lot.errors[:term_months], "must be greater than 0"
  end

  test "inherits subtype and rate defaults from bond" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1000
    )

    assert lot.valid?
    assert_equal "other_bond", lot.subtype
    assert_equal "fixed", lot.rate_type
    assert_equal "at_maturity", lot.coupon_frequency
  end

  test "calculates total return from elapsed time and annual rate" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2026, 1, 1),
      maturity_date: Date.new(2027, 1, 1),
      term_months: 12,
      amount: 1000,
      interest_rate: 10,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    )

    current_value = lot.estimated_current_value(on: Date.new(2026, 7, 1))
    total_return = lot.total_return_amount(on: Date.new(2026, 7, 1))
    total_return_percent = lot.total_return_percent(on: Date.new(2026, 7, 1))

    assert_in_delta 1049.59, current_value.to_f, 0.2
    assert_in_delta 49.59, total_return.to_f, 0.2
    assert_in_delta 4.959, total_return_percent.to_f, 0.05
  end

  test "builds capitalization history events" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 1),
      maturity_date: Date.new(2026, 1, 1),
      term_months: 24,
      amount: 1000,
      interest_rate: 10,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    )

    history = lot.capitalization_history(on: Date.new(2025, 1, 1))

    assert_equal 1, history.size
    assert_equal 1, history.first[:period_number]
    assert history.first[:interest_earned].positive?
    assert history.first[:full_year_capitalization]
  end

  test "total return caps accrual at maturity date" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2026, 1, 1),
      maturity_date: Date.new(2026, 7, 1),
      term_months: 6,
      amount: 1000,
      interest_rate: 12,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    )

    value_at_maturity = lot.estimated_current_value(on: Date.new(2026, 7, 1))
    value_after_maturity = lot.estimated_current_value(on: Date.new(2026, 12, 31))

    assert_in_delta value_at_maturity.to_f, value_after_maturity.to_f, 0.001
  end

  test "uses EOD inflation-linked setup after first year" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 1),
      term_months: 120,
      amount: 1000,
      subtype: "eod",
      first_period_rate: 7.0,
      inflation_margin: 1.5,
      inflation_rate_assumption: 4.0,
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    current_value = lot.estimated_current_value(on: Date.new(2026, 1, 1))

    assert current_value > 1000
  end

  test "does not require term_months for EOD because product defaults set it" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1000,
      subtype: "eod",
      rate_type: "variable",
      coupon_frequency: "at_maturity",
      first_period_rate: 6.0,
      inflation_margin: 1.5,
      inflation_rate_assumption: 4.0,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.current,
      cpi_lag_months: 2
    )

    assert lot.valid?
    assert_equal 120, lot.term_months
  end

  test "requires inflation-linked fields only for EOD and ROD" do
    eod_lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1000,
      subtype: "eod",
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_not eod_lot.valid?
    assert_includes eod_lot.errors[:first_period_rate], "can't be blank"
    assert_includes eod_lot.errors[:inflation_margin], "can't be blank"

    other_lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1000,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      term_months: 12,
      interest_rate: 4.5
    )

    assert other_lot.valid?
  end

  test "requires interest_rate for Other Bond" do
    bond = bonds(:one)
    bond.interest_rate = nil

    lot = BondLot.new(
      bond: bond,
      purchased_on: Date.current,
      amount: 1000,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      term_months: 12,
      interest_rate: nil
    )

    assert_not lot.valid?
    assert_includes lot.errors[:interest_rate], "can't be blank"
  end

  test "uses fetched GUS inflation when auto-fetch is enabled" do
    Setting.gus_inflation_import_enabled = true
    GusInflationRate.create!(year: 2024, month: 11, rate_yoy: 105.0, source: "sdp")

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 1),
      amount: 1000,
      subtype: "eod",
      first_period_rate: 7.0,
      inflation_margin: 1.5,
      inflation_rate_assumption: 1.0,
      auto_fetch_inflation: true,
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2024, 1, 1),
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    # For the second accrual year (starting 2025-01-01) with 2-month lag,
    # model reads 2024-11 CPI YoY (105.0 => 5.0%)
    # Effective year-2+ rate should be 5.0 + 1.5 = 6.5%
    value = lot.estimated_current_value(on: Date.new(2026, 1, 1))

    assert_in_delta 1139.55, value.to_f, 1.0
  ensure
    Setting.gus_inflation_import_enabled = false
  end

  test "falls back to manual inflation assumption when GUS value missing" do
    Setting.gus_inflation_import_enabled = true
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 1),
      amount: 1000,
      subtype: "eod",
      first_period_rate: 7.0,
      inflation_margin: 1.5,
      inflation_rate_assumption: 4.0,
      auto_fetch_inflation: true,
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2024, 1, 1),
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    # No CPI row => should use manual assumption 4.0 + 1.5 = 5.5% for year-2+
    value = lot.estimated_current_value(on: Date.new(2026, 1, 1))

    assert_in_delta 1128.85, value.to_f, 1.0
  ensure
    Setting.gus_inflation_import_enabled = false
  end

  test "requires manual inflation assumption when global auto-import is disabled" do
    Setting.gus_inflation_import_enabled = false

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1000,
      subtype: "eod",
      first_period_rate: 7.0,
      inflation_margin: 1.5,
      auto_fetch_inflation: true,
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.current,
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_not lot.valid?
    assert_includes lot.errors[:inflation_rate_assumption], "can't be blank"
  end

  test "current_rate_percent uses current inflation-linked period instead of first year rate" do
    Setting.gus_inflation_import_enabled = true
    GusInflationRate.create!(year: 2025, month: 1, rate_yoy: 108.0, source: "sdp")

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2014, 5, 31),
      amount: 1000,
      subtype: "rod",
      first_period_rate: 4.0,
      inflation_margin: 0.9,
      inflation_rate_assumption: 1.0,
      auto_fetch_inflation: true,
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2014, 5, 31),
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    current_rate = lot.current_rate_percent(on: Date.new(2025, 3, 31))

    assert_in_delta 8.9, current_rate.to_f, 0.001
  ensure
    Setting.gus_inflation_import_enabled = false
  end

  test "falls back to manual assumption when exact lagged CPI month is missing from GUS" do
    Setting.gus_inflation_import_enabled = true
    # Only 2025-12 exists; query for 2026-03-31 with lag=2 needs 2026-01 which is missing.
    GusInflationRate.create!(year: 2025, month: 12, rate_yoy: 103.3, source: "sdp")

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2014, 5, 31),
      amount: 1000,
      subtype: "rod",
      first_period_rate: 4.0,
      inflation_margin: 2.0,
      inflation_rate_assumption: 3.0,
      auto_fetch_inflation: true,
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2014, 5, 31)
    )

    # Without exact CPI month, falls back to manual assumption (3.0) + margin (2.0) = 5.0
    assert_in_delta 5.0, lot.current_rate_percent(on: Date.new(2026, 3, 31)).to_f, 0.001
    assert_in_delta 3.0, lot.current_inflation_component_percent(on: Date.new(2026, 3, 31)).to_f, 0.001
  ensure
    Setting.gus_inflation_import_enabled = false
  end

  test "auto-settles matured lot and withholds standard tax" do
    account = accounts(:bond)
    lot = BondLot.create!(
      bond: account.bond,
      purchased_on: Date.new(2024, 1, 1),
      amount: 1000,
      subtype: "other_bond",
      term_months: 12,
      interest_rate: 10,
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      auto_close_on_maturity: true,
      tax_strategy: "standard",
      tax_rate: 19
    )

    assert lot.settle_if_matured!(on: Date.new(2025, 2, 1))

    lot.reload
    assert_equal Date.new(2025, 1, 1), lot.closed_on
    assert lot.tax_withheld.to_d.positive?
    assert lot.settlement_amount.to_d.positive?
    settlement_entry = account.entries.order(created_at: :desc).first
    assert_includes settlement_entry.notes, "Purchase amount:"
    assert_includes settlement_entry.notes, "Total interest:"
    assert_includes settlement_entry.notes, "Tax withheld:"
  end

  test "auto-settles matured lot tax exempt for IKE/IKZE scenario" do
    account = accounts(:bond)
    account.bond.update!(tax_wrapper: "ike")

    lot = BondLot.create!(
      bond: account.bond,
      purchased_on: Date.new(2024, 1, 1),
      amount: 1000,
      subtype: "other_bond",
      term_months: 12,
      interest_rate: 10,
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      auto_close_on_maturity: true,
      tax_strategy: "exempt",
      tax_rate: 0
    )

    assert lot.settle_if_matured!(on: Date.new(2025, 2, 1))

    lot.reload
    assert_equal 0.to_d, lot.tax_withheld.to_d
    assert_in_delta lot.estimated_current_value(on: lot.maturity_date).to_f, lot.settlement_amount.to_d.to_f, 0.01
    settlement_entry = account.entries.order(created_at: :desc).first
    assert_includes settlement_entry.notes, "Purchase amount:"
    assert_includes settlement_entry.notes, "Total interest:"
    assert_includes settlement_entry.notes, "Tax withheld: none"
  end

  test "auto-buys replacement inflation-linked lot and flags rate review" do
    account = accounts(:bond)
    account.bond.update!(tax_wrapper: "ike", auto_buy_new_issues: true)

    lot = BondLot.create!(
      bond: account.bond,
      purchased_on: Date.new(2014, 5, 31),
      amount: 1000,
      subtype: "rod",
      first_period_rate: 4.0,
      inflation_margin: 0.9,
      inflation_rate_assumption: 4.0,
      auto_fetch_inflation: false,
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2014, 5, 31),
      auto_close_on_maturity: true
    )

    assert_difference -> { account.bond.bond_lots.count }, 1 do
      assert lot.settle_if_matured!(on: Date.new(2026, 6, 1))
    end

    replacement_lot = account.bond.bond_lots.order(created_at: :desc).first

    assert replacement_lot.requires_rate_review?
    assert_equal "rod", replacement_lot.subtype
    assert_nil replacement_lot.first_period_rate
    assert_nil replacement_lot.inflation_margin
    assert replacement_lot.entry.present?
  end
end
