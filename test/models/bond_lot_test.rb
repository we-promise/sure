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

  test "recomputes maturity date when term changes" do
    lot = BondLot.create!(
      bond: bonds(:one),
      purchased_on: Date.new(2026, 1, 15),
      term_months: 3,
      amount: 1000,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      interest_rate: 5.0
    )

    assert_equal Date.new(2026, 4, 15), lot.maturity_date

    lot.update!(term_months: 6)

    assert_equal Date.new(2026, 7, 15), lot.reload.maturity_date
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
    assert_equal "other", lot.subtype
    assert_equal "fixed", lot.rate_type
    assert_equal "at_maturity", lot.coupon_frequency
  end

  test "create_purchase_entry! creates and attaches entry with bond metadata" do
    account = accounts(:bond)
    lot = account.bond.bond_lots.create!(
      purchased_on: Date.new(2026, 2, 1),
      amount: 1000,
      term_months: 12,
      interest_rate: 4.0,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    )

    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      lot.create_purchase_entry!
    end

    lot.reload
    assert_not_nil lot.entry
    assert_equal Date.new(2026, 2, 1), lot.entry.date
    assert_equal 1000.to_d, lot.entry.amount
    assert_equal lot.id, lot.entry.entryable.extra["bond_lot_id"]
    assert_equal "other", lot.entry.entryable.extra["bond_subtype"]
    assert_equal 12, lot.entry.entryable.extra["bond_term_months"]
    assert_equal 4.0.to_d, lot.entry.entryable.extra["bond_interest_rate"].to_d
  end

  test "create_purchase_entry! is idempotent when entry already exists" do
    account = accounts(:bond)
    lot = account.bond.bond_lots.create!(
      purchased_on: Date.new(2026, 2, 1),
      amount: 1000,
      term_months: 12,
      interest_rate: 4.0,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    )

    first_entry = lot.create_purchase_entry!

    assert_no_difference [ "Entry.count", "Transaction.count" ] do
      second_entry = lot.create_purchase_entry!
      assert_equal first_entry.id, second_entry.id
    end
  end

  test "update_purchase_entry! updates entry and preserves unrelated extra fields" do
    account = accounts(:bond)
    entry_record = account.entries.create!(
      date: Date.new(2026, 2, 1),
      name: "Bond purchase",
      amount: 1000,
      currency: account.currency,
      entryable: Transaction.new(kind: :funds_movement, extra: { "custom" => "keep" })
    )

    lot = account.bond.bond_lots.create!(
      purchased_on: Date.new(2026, 2, 1),
      amount: 1000,
      term_months: 12,
      interest_rate: 4.0,
      subtype: "other_bond",
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      entry: entry_record
    )

    lot.update!(
      purchased_on: Date.new(2026, 2, 15),
      amount: 1200,
      term_months: 24,
      interest_rate: 4.5,
      subtype: "other_bond"
    )
    lot.update_purchase_entry!

    entry_record.reload
    assert_equal Date.new(2026, 2, 15), entry_record.date
    assert_equal 1200.to_d, entry_record.amount
    assert_equal "keep", entry_record.entryable.extra["custom"]
    assert_equal lot.id, entry_record.entryable.extra["bond_lot_id"]
    assert_equal "other", entry_record.entryable.extra["bond_subtype"]
    assert_equal 24, entry_record.entryable.extra["bond_term_months"]
    assert_equal 4.5.to_d, entry_record.entryable.extra["bond_interest_rate"].to_d
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
      term_months: 48,
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
    assert_not_includes eod_lot.errors[:interest_rate], "can't be blank"

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
    Setting.stubs(:inflation_import_enabled_effective).returns(true)
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
      inflation_provider: "gus_sdp",
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
  end

  test "keeps auto fetch enabled when inflation provider is blank" do
    Setting.stubs(:inflation_import_enabled_effective).returns(true)

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1000,
      subtype: "inflation_linked",
      auto_fetch_inflation: true,
      first_period_rate: 6.0,
      inflation_margin: 1.0,
      inflation_rate_assumption: 2.0,
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.current,
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    lot.valid?

    assert lot.auto_fetch_inflation
    assert_nil lot.inflation_provider
  end

  test "does not require first period rate for late-purchase inflation linked lot" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2026, 2, 1),
      amount: 1000,
      subtype: "inflation_linked",
      term_months: 48,
      first_period_rate: nil,
      inflation_margin: 1.0,
      inflation_rate_assumption: 3.0,
      auto_fetch_inflation: false,
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2024, 1, 1),
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert lot.valid?
    assert_not lot.needs_first_period_rate?
  end

  test "clears inflation_provider for non-inflation-linked lot" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1000,
      subtype: "other",
      auto_fetch_inflation: true,
      inflation_provider: "gus_sdp",
      term_months: 12,
      interest_rate: 4.0,
      rate_type: "fixed",
      coupon_frequency: "at_maturity"
    )

    lot.valid?

    assert_nil lot.inflation_provider
    assert_not lot.auto_fetch_inflation?
  end

  test "inflation_provider_key uses product market fallback when provider is blank" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1000,
      subtype: "inflation_linked",
      product_code: "es_letra_3m",
      first_period_rate: 4.0,
      inflation_margin: 1.0,
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_equal "es_ine", lot.send(:inflation_provider_key)
  end

  test "inflation_provider_key uses family locale fallback when provider and product are blank" do
    account = accounts(:bond)

    lot = BondLot.new(
      bond: account.bond,
      purchased_on: Date.current,
      amount: 1000,
      subtype: "inflation_linked",
      first_period_rate: 4.0,
      inflation_margin: 1.0,
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    lot.account.family.stubs(:locale).returns("es")

    assert_equal "es_ine", lot.send(:inflation_provider_key)
  end

  test "inflation_provider_key preserves explicit provider over derived defaults" do
    account = accounts(:bond)
    account.family.stubs(:locale).returns("pl")

    lot = BondLot.new(
      bond: account.bond,
      purchased_on: Date.current,
      amount: 1000,
      subtype: "inflation_linked",
      first_period_rate: 4.0,
      inflation_margin: 1.0,
      inflation_provider: "us_bls",
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_equal "us_bls", lot.send(:inflation_provider_key)
  end

  test "coupon_amount_per_period computes value for periodic coupon bonds" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1200,
      subtype: "fixed_coupon",
      term_months: 24,
      interest_rate: 6,
      rate_type: "fixed",
      coupon_frequency: "semi_annual"
    )

    coupon = lot.coupon_amount_per_period

    assert_in_delta 36.0, coupon.amount.to_f, 0.001
  end

  test "coupon_amount_per_period supports all periodic frequencies" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1200,
      subtype: "fixed_coupon",
      term_months: 24,
      interest_rate: 6,
      rate_type: "fixed"
    )

    {
      "monthly" => 6.0,
      "quarterly" => 18.0,
      "semi_annual" => 36.0,
      "annual" => 72.0
    }.each do |frequency, expected_amount|
      lot.coupon_frequency = frequency
      coupon = lot.coupon_amount_per_period
      assert_in_delta expected_amount, coupon.amount.to_f, 0.001
    end

    lot.coupon_frequency = "at_maturity"
    assert_nil lot.coupon_amount_per_period
  end

  test "coupon_amount_per_period uses dynamic rate for inflation-linked periodic bond" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 1),
      issue_date: Date.new(2024, 1, 1),
      amount: 1200,
      subtype: "inflation_linked",
      term_months: 120,
      coupon_frequency: "semi_annual",
      first_period_rate: 4.0,
      inflation_margin: 2.0,
      inflation_rate_assumption: 3.0,
      auto_fetch_inflation: false,
      cpi_lag_months: 2,
      units: 12,
      nominal_per_unit: 100,
      rate_type: "variable"
    )

    coupon = lot.coupon_amount_per_period(on: Date.new(2026, 3, 31))

    # Year 2+ annual rate = inflation assumption (3.0) + margin (2.0) = 5.0%
    # Semi-annual coupon for 1200 principal = 1200 * 5% / 2 = 30.0
    assert_in_delta 30.0, coupon.amount.to_f, 0.001
  end

  test "coupon_amount_per_period does not import inflation data by default" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 1),
      issue_date: Date.new(2024, 1, 1),
      amount: 1200,
      subtype: "inflation_linked",
      product_code: "us_tips_10y",
      term_months: 120,
      coupon_frequency: "semi_annual",
      first_period_rate: 4.0,
      inflation_margin: 2.0,
      inflation_rate_assumption: 3.0,
      auto_fetch_inflation: true,
      cpi_lag_months: 2,
      units: 12,
      nominal_per_unit: 100,
      rate_type: "variable"
    )

    Bond::InflationProvider.expects(:record_for_date).with(
      provider: "us_bls",
      date: Date.new(2026, 1, 1),
      lag_months: 2,
      allow_import: false
    ).returns(nil)

    coupon = lot.coupon_amount_per_period(on: Date.new(2026, 3, 31))

    assert_in_delta 30.0, coupon.amount.to_f, 0.001
  end

  test "estimated_current_value for periodic coupon bond excludes already paid coupons" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 1),
      maturity_date: Date.new(2025, 1, 1),
      term_months: 12,
      amount: 1000,
      interest_rate: 12,
      subtype: "fixed_coupon",
      rate_type: "fixed",
      coupon_frequency: "semi_annual"
    )

    value = lot.estimated_current_value(on: Date.new(2024, 9, 1))

    assert_in_delta 1020.33, value.to_f, 0.2
  end

  test "product change re-resolves inflation provider from product defaults" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1000,
      product_code: "us_tips_10y",
      first_period_rate: 4.0,
      inflation_margin: 1.0,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.current
    )

    assert lot.valid?
    assert_equal "us_bls", lot.inflation_provider

    lot.product_code = "pl_eod"
    assert lot.valid?
    assert_equal "gus_sdp", lot.inflation_provider
  end

  test "derive_amount_from_units keeps explicit non-par amount for non-inflation lots" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 950,
      subtype: "fixed_coupon",
      term_months: 12,
      interest_rate: 5,
      rate_type: "fixed",
      coupon_frequency: "semi_annual",
      units: 10,
      nominal_per_unit: 100
    )

    assert lot.valid?
    assert_equal 950.to_d, lot.amount.to_d
  end

  test "product presets override conflicting rate and coupon settings" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1000,
      product_code: "us_t_note_2y",
      subtype: "other",
      rate_type: "variable",
      coupon_frequency: "at_maturity",
      term_months: 6,
      interest_rate: 4.5
    )

    assert lot.valid?
    assert_equal "fixed_coupon", lot.subtype
    assert_equal "fixed", lot.rate_type
    assert_equal "semi_annual", lot.coupon_frequency
    assert_equal 24, lot.term_months
  end

  test "product presets set inflation provider for TIPS lots" do
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.current,
      amount: 1000,
      product_code: "us_tips_10y",
      first_period_rate: 4.0,
      inflation_margin: 1.0,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.current
    )

    assert lot.valid?
    assert_equal "us_bls", lot.inflation_provider
  end

  test "falls back to manual inflation assumption when GUS value missing" do
    Setting.stubs(:inflation_import_enabled_effective).returns(true)
    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 1),
      amount: 1000,
      subtype: "eod",
      first_period_rate: 7.0,
      inflation_margin: 1.5,
      inflation_rate_assumption: 4.0,
      auto_fetch_inflation: true,
      inflation_provider: "gus_sdp",
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
  end

  test "does not require manual inflation assumption when global auto-import is disabled" do
    Setting.stubs(:inflation_import_enabled_effective).returns(false)

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

    assert lot.valid?
  end

  test "current_rate_percent uses current inflation-linked period instead of first year rate" do
    Setting.stubs(:inflation_import_enabled_effective).returns(true)
    GusInflationRate.create!(year: 2024, month: 3, rate_yoy: 108.0, source: "sdp")

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2014, 5, 31),
      amount: 1000,
      subtype: "rod",
      first_period_rate: 4.0,
      inflation_margin: 0.9,
      inflation_rate_assumption: 1.0,
      auto_fetch_inflation: true,
      inflation_provider: "gus_sdp",
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2014, 5, 31),
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    current_rate = lot.current_rate_percent(on: Date.new(2025, 3, 31))

    assert_in_delta 8.9, current_rate.to_f, 0.001
  end

  test "uses us_bls provider when selected on inflation-linked lot" do
    Bond::InflationProvider.stubs(:record_for_date).with(provider: "us_bls", date: Date.new(2024, 5, 31), lag_months: 2, allow_import: true)
                           .returns(Bond::InflationProvider::InflationRecord.new(year: 2024, month: 3, rate_yoy: 106.2))

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2014, 5, 31),
      amount: 1000,
      subtype: "inflation_linked",
      first_period_rate: 4.0,
      inflation_margin: 0.9,
      inflation_rate_assumption: 1.0,
      inflation_provider: "us_bls",
      auto_fetch_inflation: true,
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2014, 5, 31),
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_in_delta 7.1, lot.current_rate_percent(on: Date.new(2025, 3, 31)).to_f, 0.001
    assert_equal "us_bls", lot.current_inflation_source(on: Date.new(2025, 3, 31))
    assert_in_delta 6.2, lot.current_inflation_component_percent(on: Date.new(2025, 3, 31)).to_f, 0.001
  end

  test "falls back to manual assumption when non-gus provider returns no CPI data" do
    Bond::InflationProvider.stubs(:record_for_date).with(provider: "es_ine", date: Date.new(2024, 5, 31), lag_months: 2, allow_import: true)
                           .returns(nil)

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2014, 5, 31),
      amount: 1000,
      subtype: "inflation_linked",
      first_period_rate: 4.0,
      inflation_margin: 2.0,
      inflation_rate_assumption: 3.0,
      inflation_provider: "es_ine",
      auto_fetch_inflation: true,
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2014, 5, 31),
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_in_delta 5.0, lot.current_rate_percent(on: Date.new(2025, 3, 31)).to_f, 0.001
    assert_equal "manual", lot.current_inflation_source(on: Date.new(2025, 3, 31))
  end

  test "falls back to manual assumption when exact lagged CPI month is missing from GUS" do
    Setting.stubs(:inflation_import_enabled_effective).returns(true)
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
      inflation_provider: "gus_sdp",
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2014, 5, 31)
    )

    # Without exact CPI month, falls back to manual assumption (3.0) + margin (2.0) = 5.0
    assert_in_delta 5.0, lot.current_rate_percent(on: Date.new(2026, 3, 31)).to_f, 0.001
    assert_in_delta 3.0, lot.current_inflation_component_percent(on: Date.new(2026, 3, 31)).to_f, 0.001
  end

  test "keeps CPI reference stable within the same annual reset period" do
    Setting.stubs(:inflation_import_enabled_effective).returns(true)
    GusInflationRate.create!(year: 2024, month: 11, rate_yoy: 105.0, source: "sdp")
    GusInflationRate.create!(year: 2025, month: 7, rate_yoy: 109.0, source: "sdp")

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 15),
      amount: 1000,
      subtype: "rod",
      first_period_rate: 4.0,
      inflation_margin: 1.0,
      inflation_rate_assumption: 3.0,
      auto_fetch_inflation: true,
      inflation_provider: "gus_sdp",
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2024, 1, 15),
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_equal Date.new(2024, 11, 1), lot.current_cpi_reference_on(on: Date.new(2025, 3, 31))
    assert_equal Date.new(2024, 11, 1), lot.current_cpi_reference_on(on: Date.new(2025, 9, 30))
    assert_in_delta 6.0, lot.current_rate_percent(on: Date.new(2025, 3, 31)).to_f, 0.001
    assert_in_delta 6.0, lot.current_rate_percent(on: Date.new(2025, 9, 30)).to_f, 0.001
  end

  test "keeps CPI read path enabled when global import toggle is off" do
    Setting.stubs(:inflation_import_enabled_effective).returns(false)
    GusInflationRate.create!(year: 2024, month: 3, rate_yoy: 108.0, source: "sdp")

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2014, 5, 31),
      amount: 1000,
      subtype: "rod",
      first_period_rate: 4.0,
      inflation_margin: 0.9,
      inflation_rate_assumption: 1.0,
      auto_fetch_inflation: true,
      inflation_provider: "gus_sdp",
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2014, 5, 31),
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_in_delta 8.0, lot.current_inflation_component_percent(on: Date.new(2025, 3, 31)).to_f, 0.001
    assert_equal "gus_sdp", lot.current_inflation_source(on: Date.new(2025, 3, 31))
    assert_in_delta 0.9, lot.current_margin_percent(on: Date.new(2025, 3, 31)).to_f, 0.001
  end

  test "hides inflation breakdown during first period" do
    Setting.stubs(:inflation_import_enabled_effective).returns(true)
    GusInflationRate.create!(year: 2024, month: 3, rate_yoy: 106.0, source: "sdp")

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 5, 31),
      amount: 1000,
      subtype: "rod",
      first_period_rate: 4.0,
      inflation_margin: 0.9,
      inflation_rate_assumption: 1.0,
      auto_fetch_inflation: true,
      inflation_provider: "gus_sdp",
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2024, 5, 31),
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_nil lot.current_inflation_component_percent(on: Date.new(2024, 10, 1))
    assert_nil lot.current_inflation_source(on: Date.new(2024, 10, 1))
    assert_nil lot.current_margin_percent(on: Date.new(2024, 10, 1))
  end

  test "does not clear requires_rate_review while CPI periods are unresolved" do
    Setting.stubs(:inflation_import_enabled_effective).returns(true)

    lot = BondLot.new(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 1),
      amount: 1000,
      subtype: "rod",
      term_months: 24,
      first_period_rate: 4.0,
      inflation_margin: 0.9,
      auto_fetch_inflation: true,
      inflation_provider: "gus_sdp",
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2024, 1, 1),
      requires_rate_review: true,
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    lot.valid?

    assert lot.requires_rate_review?
  end

  test "needs_rate_review ignores stale persisted flags once CPI is resolvable" do
    Setting.stubs(:inflation_import_enabled_effective).returns(true)
    # Period 2 starts at 2025-01-01; CPI reference = 2025-01-01 - 2 lag months = Nov 2024
    GusInflationRate.create!(year: 2024, month: 11, rate_yoy: 108.0, source: "sdp")

    lot = BondLot.create!(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 1),
      amount: 1000,
      subtype: "inflation_linked",
      term_months: 24,
      first_period_rate: 4.0,
      inflation_margin: 0.9,
      auto_fetch_inflation: true,
      inflation_provider: "gus_sdp",
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2024, 1, 1),
      requires_rate_review: true,
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_not_includes BondLot.needs_rate_review, lot
  end

  test "needs_rate_review uses maturity date when lot is already matured" do
    Setting.stubs(:inflation_import_enabled_effective).returns(true)
    GusInflationRate.create!(year: 2024, month: 11, rate_yoy: 106.0, source: "sdp")

    lot = BondLot.create!(
      bond: bonds(:one),
      purchased_on: Date.new(2024, 1, 1),
      amount: 1000,
      subtype: "inflation_linked",
      term_months: 12,
      maturity_date: Date.new(2025, 1, 1),
      first_period_rate: 4.0,
      inflation_margin: 0.9,
      auto_fetch_inflation: true,
      inflation_provider: "gus_sdp",
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2024, 1, 1),
      requires_rate_review: true,
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_not_includes BondLot.needs_rate_review, lot
  end

  test "needs_rate_review ignores missing first period rate after intro period" do
    lot = BondLot.create!(
      bond: bonds(:one),
      purchased_on: Date.new(2026, 2, 1),
      amount: 1000,
      subtype: "inflation_linked",
      term_months: 48,
      first_period_rate: nil,
      inflation_margin: 1.0,
      inflation_rate_assumption: 3.0,
      auto_fetch_inflation: false,
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.new(2024, 1, 1),
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )

    assert_not_includes BondLot.needs_rate_review, lot
  end

  test "does not enqueue inflation backfill for ES lots without series id" do
    Bond::InflationProvider.stubs(:automatic_import_enabled?).with("es_ine").returns(false)
    ImportInflationRatesJob.expects(:perform_later).never

    account = accounts(:bond)
    lot = account.bond.bond_lots.create!(
      purchased_on: Date.current,
      amount: 1000,
      subtype: "inflation_linked",
      term_months: 120,
      first_period_rate: 4.0,
      inflation_margin: 1.0,
      auto_fetch_inflation: true,
      inflation_provider: "es_ine",
      cpi_lag_months: 2,
      units: 10,
      nominal_per_unit: 100,
      issue_date: Date.current,
      rate_type: "variable",
      coupon_frequency: "at_maturity"
    )
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

  test "auto-settles lot immediately when created already after maturity" do
    account = accounts(:bond)
    lot = account.bond.bond_lots.build(
      bond: account.bond,
      purchased_on: Date.new(2013, 4, 7),
      amount: 1000,
      subtype: "fixed_coupon",
      term_months: 120,
      issue_date: Date.new(2013, 4, 7),
      interest_rate: 5.0,
      rate_type: "fixed",
      coupon_frequency: "at_maturity",
      auto_close_on_maturity: true
    )

    lot.save_with_purchase_entry!

    lot.reload

    assert lot.closed_on.present?
    assert_equal lot.maturity_date, lot.closed_on
    assert lot.settlement_amount.to_d.positive?
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

  test "auto-settlement for periodic coupon bond excludes previously paid coupons" do
    account = accounts(:bond)
    account.bond.update!(tax_wrapper: "ike")

    lot = BondLot.create!(
      bond: account.bond,
      purchased_on: Date.new(2024, 1, 1),
      amount: 1000,
      subtype: "fixed_coupon",
      term_months: 12,
      interest_rate: 12,
      rate_type: "fixed",
      coupon_frequency: "semi_annual",
      auto_close_on_maturity: true,
      tax_strategy: "exempt",
      tax_rate: 0
    )

    assert lot.settle_if_matured!(on: Date.new(2025, 2, 1))

    lot.reload
    assert_in_delta 1060.33, lot.settlement_amount.to_d.to_f, 0.2
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
    lot.update_column(:coupon_frequency, "annual")
    lot.reload

    assert_difference -> { account.bond.bond_lots.count }, 1 do
      assert lot.settle_if_matured!(on: Date.new(2026, 6, 1))
    end

    replacement_lot = account.bond.bond_lots.order(created_at: :desc).first

    assert replacement_lot.requires_rate_review?
    assert_equal "inflation_linked", replacement_lot.subtype
    assert_equal "annual", replacement_lot.coupon_frequency
    assert_nil replacement_lot.first_period_rate
    assert_nil replacement_lot.inflation_margin
    assert replacement_lot.entry.present?
  end
end
