require "test_helper"

class PurchasesHelperTest < ActionView::TestCase
  test "a month group's title names the month on its own, not as part of a date" do
    month = Date.new(2026, 11, 1)

    assert_equal "November 2026", purchase_month_title(month)
    I18n.with_locale(:pl) { assert_equal "Listopad 2026", purchase_month_title(month) }
  end
end
