require "test_helper"

class MonthlySpendingChartTest < ActiveSupport::TestCase
  test "subunit currency amounts remain visible rather than using a one-unit floor" do
    chart = DS::MonthlySpendingChart.new(data: { months: [ { total: "0.00001" } ] })
    assert_equal 100, chart.percentage("0.00001")
    assert_equal 50, chart.percentage("0.000005")
  end
end

class MonthlySpendingHelperTest < ActionView::TestCase
  helper ReportsHelper
  test "category share is relative to the displayed month total with safe zero handling" do
    I18n.with_locale(:en) do
      assert_equal "52.5%", monthly_spending_share("850", "1618")
      assert_equal "100%", monthly_spending_share("850", "850")
      assert_equal "—", monthly_spending_share("0", "0")
    end
    I18n.with_locale(:de) do
      assert_equal "52,5%", monthly_spending_share("850", "1618")
    end
  end
end
