require "test_helper"

class GusInflationRateTest < ActiveSupport::TestCase
  test "enforces uniqueness per year and month" do
    GusInflationRate.create!(year: 2025, month: 1, rate_yoy: 104.7, source: "sdp")

    duplicate = GusInflationRate.new(year: 2025, month: 1, rate_yoy: 105.0, source: "sdp")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:month], "has already been taken"
  end

  test "allows same month in different years" do
    GusInflationRate.create!(year: 2025, month: 1, rate_yoy: 104.7, source: "sdp")

    next_year = GusInflationRate.new(year: 2026, month: 1, rate_yoy: 102.1, source: "sdp")

    assert next_year.valid?
  end

  test "for_date applies lag months" do
    GusInflationRate.create!(year: 2025, month: 12, rate_yoy: 104.7, source: "sdp")

    record = GusInflationRate.for_date(date: Date.new(2026, 2, 5), lag_months: 2)

    assert_not_nil record
    assert_equal 2025, record.year
    assert_equal 12, record.month
    assert_equal 104.7.to_d, record.rate_yoy
  end

  test "import_year maps period IDs to months" do
    fake_provider = mock("provider")
    fake_provider.expects(:fetch_cpi_yoy_for_year).with(year: 2026).returns(
      Provider::Response.new(
        success?: true,
        data: [
          { period_id: 247, value: "102.1" },
          { period_id: 248, value: "103.3" }
        ],
        error: nil
      )
    )

    GusInflationRate.stubs(:provider).returns(fake_provider)

    imported = GusInflationRate.import_year!(year: 2026)

    assert_equal 2, imported
    assert_equal 102.1.to_d, GusInflationRate.find_by!(year: 2026, month: 1).rate_yoy
    assert_equal 103.3.to_d, GusInflationRate.find_by!(year: 2026, month: 2).rate_yoy
  end

  test "import_year raises provider error when request fails" do
    fake_provider = mock("provider")
    fake_provider.expects(:fetch_cpi_yoy_for_year).with(year: 2026).returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("boom"))
    )

    GusInflationRate.stubs(:provider).returns(fake_provider)

    error = assert_raises(Provider::Error) { GusInflationRate.import_year!(year: 2026) }
    assert_equal "boom", error.message
  end

  test "import_year returns zero when provider responds with 404 for unavailable year" do
    fake_provider = mock("provider")
    fake_provider.expects(:fetch_cpi_yoy_for_year).with(year: 2026).returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("the server responded with status 404"))
    )

    GusInflationRate.stubs(:provider).returns(fake_provider)

    assert_equal 0, GusInflationRate.import_year!(year: 2026)
  end

  test "import_year raises error when provider responds with 429 rate limit" do
    fake_provider = mock("provider")
    fake_provider.expects(:fetch_cpi_yoy_for_year).with(year: 2026).returns(
      Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("the server responded with status 429"))
    )

    GusInflationRate.stubs(:provider).returns(fake_provider)

    error = assert_raises(Provider::Error) { GusInflationRate.import_year!(year: 2026) }
    assert_match(/429/, error.message)
  end

  test "import_year skips provider call for complete year when force is false" do
    (1..12).each do |month|
      GusInflationRate.create!(year: 2025, month: month, rate_yoy: 101.0 + month, source: "sdp")
    end

    fake_provider = mock("provider")
    fake_provider.expects(:fetch_cpi_yoy_for_year).never
    GusInflationRate.stubs(:provider).returns(fake_provider)

    assert_equal 0, GusInflationRate.import_year!(year: 2025, force: false)
  end
end
