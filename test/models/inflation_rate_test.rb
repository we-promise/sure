require "test_helper"

class InflationRateTest < ActiveSupport::TestCase
  test "for_date applies lag months and source" do
    InflationRate.create!(source: "us_bls", year: 2025, month: 1, rate_yoy: 103.2)

    record = InflationRate.for_date(source: "us_bls", date: Date.new(2025, 3, 15), lag_months: 2)

    assert_not_nil record
    assert_equal 2025, record.year
    assert_equal 1, record.month
    assert_equal 103.2.to_d, record.rate_yoy
  end

  test "import_year persists provider rows" do
    fake_provider = mock("provider")
    fake_provider.expects(:fetch_cpi_yoy_for_year).with(year: 2025).returns(
      Provider::Response.new(
        success?: true,
        data: [
          { month: 1, rate_yoy: 103.1 },
          { month: 2, rate_yoy: 103.4 }
        ],
        error: nil
      )
    )

    imported = InflationRate.import_year!(source: "us_bls", provider: fake_provider, year: 2025)

    assert_equal 2, imported
    assert_equal 103.1.to_d, InflationRate.find_by!(source: "us_bls", year: 2025, month: 1).rate_yoy
    assert_equal 103.4.to_d, InflationRate.find_by!(source: "us_bls", year: 2025, month: 2).rate_yoy
  end
end
