require "test_helper"

class Provider::EsIneCpiTest < ActiveSupport::TestCase
  test "fetch_cpi_yoy_for_year filters rows to requested year" do
    provider = Provider::EsIneCpi.new(series_id: "IPC_TEST")
    provider.stubs(:fetch_rows).returns([
      { year: 2024, month: 12, rate_yoy: 102.1.to_d },
      { year: 2025, month: 1, rate_yoy: 103.4.to_d },
      { year: 2025, month: 2, rate_yoy: 103.7.to_d }
    ])

    result = provider.fetch_cpi_yoy_for_year(year: 2025)

    assert result.success?
    assert_equal 2, result.data.size
    assert_equal({ month: 1, rate_yoy: 103.4.to_d }, result.data[0])
    assert_equal({ month: 2, rate_yoy: 103.7.to_d }, result.data[1])
  end

  test "fetch_cpi_yoy_for_year returns error when series id missing" do
    provider = Provider::EsIneCpi.new(series_id: nil)

    result = provider.fetch_cpi_yoy_for_year(year: 2025)

    assert_not result.success?
    assert_instance_of Provider::EsIneCpi::Error, result.error
    assert_match(/Missing ES_INE_CPI_SERIES_ID/, result.error.message)
  end

  test "fetch_cpi_yoy_for_year returns error when requested year has no rows" do
    provider = Provider::EsIneCpi.new(series_id: "IPC_TEST")
    provider.stubs(:fetch_rows).returns([
      { year: 2024, month: 12, rate_yoy: 102.1.to_d }
    ])

    result = provider.fetch_cpi_yoy_for_year(year: 2025)

    assert_not result.success?
    assert_instance_of Provider::EsIneCpi::Error, result.error
    assert_match(/No ES INE CPI data returned for 2025/, result.error.message)
  end
end
