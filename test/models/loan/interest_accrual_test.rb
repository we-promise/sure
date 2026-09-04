require "test_helper"

class Loan::InterestAccrualTest < ActiveSupport::TestCase
  test "a non-leap full year equals balance times annual rate" do
    interest = accrue(
      from_date: Date.new(2023, 1, 1),
      to_date: Date.new(2024, 1, 1),
      balance: "1000",
      annual_rate: "12"
    )

    assert_equal BigDecimal("120"), interest.round(20)
  end

  test "actual elapsed days make a 31-day month exceed a 28-day month" do
    long_month = accrue(from_date: Date.new(2024, 1, 1), to_date: Date.new(2024, 2, 1), balance: "1000", annual_rate: "12")
    short_month = accrue(from_date: Date.new(2024, 2, 1), to_date: Date.new(2024, 2, 29), balance: "1000", annual_rate: "12")

    assert_operator long_month, :>, short_month
    assert_equal BigDecimal("10.19178082191780821918"), long_month.round(20)
    assert_equal BigDecimal("9.20547945205479452055"), short_month.round(20)
  end

  test "leap-year accrual uses 366 elapsed days over the 365 denominator" do
    interest = accrue(
      from_date: Date.new(2024, 1, 1),
      to_date: Date.new(2025, 1, 1),
      balance: "1000",
      annual_rate: "12"
    )

    expected = (BigDecimal("120") * BigDecimal("366") / BigDecimal("365")).round(20)
    assert_equal expected, interest.round(20)
  end

  test "piecewise segments equal the equivalent daily loop" do
    changes = [ { date: Date.new(2024, 1, 11), amount: "200" }, { date: Date.new(2024, 1, 21), amount: "700" } ]
    segmented = accrue(
      from_date: Date.new(2024, 1, 1), to_date: Date.new(2024, 2, 1),
      balance: "1000", annual_rate: "12", offset_changes: changes
    )
    daily = (1...32).sum do |day|
      date = Date.new(2024, 1, 1) + day - 1
      offset = changes.reverse_each.find { |change| change[:date] <= date }&.fetch(:amount, "0") || "0"
      [ BigDecimal("1000") - BigDecimal(offset), BigDecimal("0") ].max * BigDecimal("12") / 100 / 365
    end

    assert_equal daily.round(20), segmented.round(20)
  end

  test "a unified change-point list applies balance, offset, and rate changes" do
    change_points = [
      { date: Date.new(2024, 1, 1), balance: "1000", offset: "0", rate: "12" },
      { date: Date.new(2024, 1, 11), balance: "1000", offset: "200", rate: "12" },
      { date: Date.new(2024, 1, 21), balance: "900", offset: "200", rate: "6" }
    ]
    segmented = accrue(
      from_date: Date.new(2024, 1, 1), to_date: Date.new(2024, 2, 1),
      balance: "1000", annual_rate: "12", change_points: change_points
    )

    daily = (Date.new(2024, 1, 1)...Date.new(2024, 2, 1)).sum do |date|
      balance = date < Date.new(2024, 1, 21) ? BigDecimal("1000") : BigDecimal("900")
      offset = date < Date.new(2024, 1, 11) ? BigDecimal("0") : BigDecimal("200")
      rate = date < Date.new(2024, 1, 21) ? BigDecimal("12") : BigDecimal("6")
      [ balance - offset, BigDecimal("0") ].max * rate / 100 / 365
    end

    assert_equal daily.round(20), segmented.round(20)
  end

  test "offset at or above the balance produces no interest for that segment" do
    interest = accrue(
      from_date: Date.new(2024, 1, 1), to_date: Date.new(2024, 2, 1),
      balance: "1000", annual_rate: "12",
      offset_changes: [ { date: Date.new(2024, 1, 15), amount: "1200" } ]
    )

    expected = (BigDecimal("14") * BigDecimal("12") / 100 / 365 * 1000).round(20)
    assert_equal expected, interest.round(20)
  end

  test "an offset change at the range start applies to the full range" do
    interest = accrue(
      from_date: Date.new(2024, 1, 1), to_date: Date.new(2024, 2, 1),
      balance: "1000", annual_rate: "12",
      offset_changes: [ { date: Date.new(2024, 1, 1), amount: "1000" } ]
    )

    assert_equal BigDecimal("0"), interest
  end

  test "charge rounds once after unrounded accumulation" do
    interest = Loan::InterestAccrual.charge(
      currency_precision: 2,
      from_date: Date.new(2024, 1, 1), to_date: Date.new(2024, 2, 1),
      balance: "1000", annual_rate: "12"
    )

    assert_equal BigDecimal("10.19"), interest
  end

  private

    def accrue(**args)
      Loan::InterestAccrual.calculate(**args)
    end
end
