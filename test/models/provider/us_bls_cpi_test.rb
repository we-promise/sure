require "test_helper"

class Provider::UsBlsCpiTest < ActiveSupport::TestCase
  test "fetch_cpi_yoy_for_year calculates monthly yoy values from index series" do
    provider = Provider::UsBlsCpi.new
    provider.stubs(:fetch_series_rows).returns([
      { year: 2024, month: 1, value: 100.to_d },
      { year: 2024, month: 2, value: 100.to_d },
      { year: 2025, month: 1, value: 103.to_d },
      { year: 2025, month: 2, value: 104.to_d }
    ])

    result = provider.fetch_cpi_yoy_for_year(year: 2025)

    assert result.success?
    assert_equal 2, result.data.size
    assert_equal 1, result.data[0][:month]
    assert_equal 103.0.to_d, result.data[0][:rate_yoy]
    assert_equal 2, result.data[1][:month]
    assert_equal 104.0.to_d, result.data[1][:rate_yoy]
  end

  test "fetch_cpi_yoy_for_year returns provider error when api status is failed" do
    provider = Provider::UsBlsCpi.new
    provider.stubs(:fetch_series_rows).raises(Provider::UsBlsCpi::Error.new("BLS API request failed with status REQUEST_FAILED"))

    result = provider.fetch_cpi_yoy_for_year(year: 2025)

    assert_not result.success?
    assert_instance_of Provider::UsBlsCpi::Error, result.error
    assert_match(/REQUEST_FAILED/, result.error.message)
  end
end
