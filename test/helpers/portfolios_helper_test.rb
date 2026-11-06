require "test_helper"

class PortfoliosHelperTest < ActionView::TestCase
  include PortfoliosHelper

  test "a holdings header flips its own direction and opens another column on its natural one" do
    active = { active_sort: "value", active_dir: "desc" }

    assert_equal portfolio_path(sort: "value", dir: "asc"), holdings_sort_link("value", **active)
    assert_equal portfolio_path(sort: "value", dir: "desc"), holdings_sort_link("value", active_sort: "value", active_dir: "asc")
    assert_equal portfolio_path(sort: "name", dir: "asc"), holdings_sort_link("name", **active)
    assert_equal portfolio_path(sort: "weight", dir: "desc"), holdings_sort_link("weight", **active)
  end

  test "only the active holdings column carries an aria-sort value" do
    assert_equal "ascending", holdings_aria_sort("name", active_sort: "name", active_dir: "asc")
    assert_equal "descending", holdings_aria_sort("name", active_sort: "name", active_dir: "desc")
    assert_nil holdings_aria_sort("value", active_sort: "name", active_dir: "asc")
    assert_nil holdings_aria_sort(nil, active_sort: "name", active_dir: "asc")
  end

  # The period-return card's hint. Three branches a regression would break
  # silently: the plain label when nothing was excluded, the singular and
  # plural disclosure, and the concatenation that keeps the comparison label
  # in front of it.
  class KpiPeriodReturnHintTest < ActionView::TestCase
    include PortfoliosHelper

    setup { @period = Period.current_month }

    test "no disclosure when everything converted" do
      assert_equal @period.comparison_label, kpi_period_return_hint(@period, 0)
      assert_equal @period.comparison_label, kpi_period_return_hint(@period, nil)
    end

    test "one excluded account reads in the singular" do
      hint = kpi_period_return_hint(@period, 1)

      assert_includes hint, @period.comparison_label, "the comparison label was dropped"
      assert_match(/1 account/, hint)
      assert_no_match(/accounts/, hint, "singular count used the plural string")
    end

    test "more than one reads in the plural, with the count" do
      hint = kpi_period_return_hint(@period, 3)

      assert_includes hint, @period.comparison_label
      assert_match(/3 accounts/, hint)
    end
  end
end
