require "test_helper"

class MonthlySpendingChartTest < ActiveSupport::TestCase
  test "subunit currency amounts remain visible rather than using a one-unit floor" do
    chart = DS::MonthlySpendingChart.new(data: { months: [ { total: "0.00001" } ] })
    assert_equal 100, chart.percentage("0.00001")
    assert_equal 50, chart.percentage("0.000005")
  end
end
