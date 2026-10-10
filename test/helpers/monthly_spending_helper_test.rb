require "test_helper"

class MonthlySpendingHelperTest < ActionView::TestCase
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
