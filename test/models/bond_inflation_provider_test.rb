require "test_helper"

class BondInflationProviderTest < ActiveSupport::TestCase
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

  test "record_for_date reads from provider adapter for non-gus providers" do
    fake_adapter = mock("adapter")
    fake_adapter.expects(:fetch_cpi_yoy_for_year).with(year: 2025).returns(
      Provider::Response.new(
        success?: true,
        data: [ { month: 1, rate_yoy: 106.4.to_d } ],
        error: nil
      )
    )

    Bond::InflationProvider.stubs(:provider_class).with("us_bls").returns(stub(new: fake_adapter))

    record = Bond::InflationProvider.record_for_date(
      provider: "us_bls",
      date: Date.new(2025, 3, 10),
      lag_months: 2
    )

    assert_not_nil record
    assert_equal 2025, record.year
    assert_equal 1, record.month
    assert_equal 106.4.to_d, record.rate_yoy
  end
end
