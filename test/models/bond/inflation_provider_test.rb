require "test_helper"

class BondInflationProviderTest < ActiveSupport::TestCase
  test "default_provider_for derives provider from product code market" do
    assert_equal "gus_sdp", Bond::InflationProvider.default_provider_for(product_code: "pl_eod")
    assert_equal "us_bls", Bond::InflationProvider.default_provider_for(product_code: "us_tips_10y")
    assert_equal "es_ine", Bond::InflationProvider.default_provider_for(product_code: "es_letra_3m")
  end

  test "default_provider_for falls back to locale when product code is absent" do
    assert_equal "gus_sdp", Bond::InflationProvider.default_provider_for(locale: "pl")
    assert_equal "us_bls", Bond::InflationProvider.default_provider_for(locale: "en-US")
    assert_equal "es_ine", Bond::InflationProvider.default_provider_for(locale: "es")
  end

  test "default_provider_for falls back to gus_sdp for unknown locale" do
    assert_equal "gus_sdp", Bond::InflationProvider.default_provider_for(locale: "de")
  end

  test "record_for_date reads from GUS storage for gus_sdp provider" do
    GusInflationRate.create!(year: 2025, month: 1, rate_yoy: 105.2, source: "sdp")

    record = Bond::InflationProvider.record_for_date(
      provider: "gus_sdp",
      date: Date.new(2025, 3, 10),
      lag_months: 2
    )

    assert_not_nil record
    assert_equal 2025, record.year
    assert_equal 1, record.month
    assert_equal 105.2.to_d, record.rate_yoy
  end

  test "record_for_date attempts GUS on-demand import when allow_import is true" do
    target_date = Date.new(2025, 3, 10)

    Bond::InflationProvider.expects(:automatic_import_enabled?).with("gus_sdp").returns(true)

    GusInflationRate.expects(:for_date).with(date: target_date, lag_months: 2).twice.returns(nil)
    GusInflationRate.expects(:import_year!).with(year: 2025).once

    record = Bond::InflationProvider.record_for_date(
      provider: "gus_sdp",
      date: target_date,
      lag_months: 2,
      allow_import: true
    )

    assert_nil record
  end

  test "record_for_date reads from provider adapter for non-gus providers" do
    fake_adapter = mock("adapter")
    fake_adapter.expects(:fetch_cpi_yoy_for_year).with(year: 2025).returns(
      Provider::Response.new(
        success?: true,
        data: [ { month: 1, rate_yoy: 106.4.to_d } ],
        error: nil
      )
    ).once

    provider_klass = mock("provider_klass")
    provider_klass.stubs(:new).returns(fake_adapter)
    Bond::InflationProvider.stubs(:provider_class).with("us_bls").returns(provider_klass)

    record = Bond::InflationProvider.record_for_date(
      provider: "us_bls",
      date: Date.new(2025, 3, 10),
      lag_months: 2
    )

    # Second call should use persisted data and avoid extra provider call.
    second_record = Bond::InflationProvider.record_for_date(
      provider: "us_bls",
      date: Date.new(2025, 3, 10),
      lag_months: 2
    )

    assert_not_nil record
    assert_equal 2025, record.year
    assert_equal 1, record.month
    assert_equal 106.4.to_d, record.rate_yoy
    assert_not_nil second_record
    assert_equal 106.4.to_d, second_record.rate_yoy
    assert_equal 1, InflationRate.where(source: "us_bls", year: 2025, month: 1).count
  end

  test "record_for_date uses self-hosted settings to configure us_bls provider" do
    fake_adapter = mock("adapter")
    fake_adapter.expects(:fetch_cpi_yoy_for_year).with(year: 2025).returns(
      Provider::Response.new(success?: true, data: [ { month: 1, rate_yoy: 104.0.to_d } ], error: nil)
    ).once

    provider_klass = mock("provider_klass")
    provider_klass.expects(:new).with(base_url: "https://example-bsl.test", series_id: "SERIES_123").returns(fake_adapter)
    Bond::InflationProvider.stubs(:provider_class).with("us_bls").returns(provider_klass)

    old_base_url = Setting.us_bls_cpi_base_url
    old_series_id = Setting.us_bls_cpi_series_id
    Setting.us_bls_cpi_base_url = "https://example-bsl.test"
    Setting.us_bls_cpi_series_id = "SERIES_123"

    begin
      record = with_env_overrides("US_BLS_CPI_BASE_URL" => nil, "US_BLS_CPI_SERIES_ID" => nil) do
        Bond::InflationProvider.record_for_date(
          provider: "us_bls",
          date: Date.new(2025, 3, 10),
          lag_months: 2
        )
      end

      assert_not_nil record
      assert_equal 104.0.to_d, record.rate_yoy
    ensure
      Setting.us_bls_cpi_base_url = old_base_url
      Setting.us_bls_cpi_series_id = old_series_id
    end
  end

  test "record_for_date with allow_import false reads only persisted non-gus data" do
    InflationRate.create!(source: "us_bls", year: 2025, month: 1, rate_yoy: 105.7)

    Bond::InflationProvider.expects(:provider_class).never

    record = Bond::InflationProvider.record_for_date(
      provider: "us_bls",
      date: Date.new(2025, 3, 10),
      lag_months: 2,
      allow_import: false
    )

    assert_not_nil record
    assert_equal 105.7.to_d, record.rate_yoy

    missing = Bond::InflationProvider.record_for_date(
      provider: "es_ine",
      date: Date.new(2025, 3, 10),
      lag_months: 2,
      allow_import: false
    )

    assert_nil missing
  end

  test "record_for_date does not attempt ES import when series id is missing" do
    old_series_id = Setting.es_ine_cpi_series_id
    Setting.es_ine_cpi_series_id = nil

    Bond::InflationProvider.expects(:provider_class).never

    record = with_env_overrides("ES_INE_CPI_SERIES_ID" => nil) do
      Bond::InflationProvider.record_for_date(
        provider: "es_ine",
        date: Date.new(2025, 3, 10),
        lag_months: 2,
        allow_import: true
      )
    end

    assert_nil record
  ensure
    Setting.es_ine_cpi_series_id = old_series_id
  end
end
