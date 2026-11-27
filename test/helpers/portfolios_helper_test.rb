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

  # A KPI card's hint. Three branches a regression would break
  # silently: the plain label when nothing was excluded, the singular and
  # plural disclosure, and the concatenation that keeps the label in front
  # of it.
  class KpiHintTest < ActionView::TestCase
    include PortfoliosHelper

    setup { @period = Period.current_month }

    test "no disclosure when everything converted" do
      assert_equal @period.comparison_label, kpi_hint(@period.comparison_label, 0)
      assert_equal @period.comparison_label, kpi_hint(@period.comparison_label, nil)
    end

    test "one excluded account reads in the singular" do
      hint = kpi_hint(@period.comparison_label, 1)

      assert_includes hint, @period.comparison_label, "the comparison label was dropped"
      assert_match(/1 account/, hint)
      assert_no_match(/accounts/, hint, "singular count used the plural string")
    end

    test "more than one reads in the plural, with the count" do
      hint = kpi_hint(@period.comparison_label, 3)

      assert_includes hint, @period.comparison_label
      assert_match(/3 accounts/, hint)
    end
  end

  class KpiPartialHintsTest < ActionView::TestCase
    include PortfoliosHelper

    test "the day change hint appears only when a position is left out" do
      assert_nil kpi_day_change_hint([ 3, 3 ])
      assert_nil kpi_day_change_hint([ 0, 0 ])
      assert_equal I18n.t("portfolios.kpi_row.day_change_partial", covered: 2, total: 3), kpi_day_change_hint([ 2, 3 ])
    end

    test "the unrealised hint appears only when a position has no cost basis" do
      assert_nil kpi_unrealized_hint(0)
      assert_equal "excludes 1 position with no cost basis", kpi_unrealized_hint(1)
      assert_equal "excludes 2 positions with no cost basis", kpi_unrealized_hint(2)
    end

    test "the unrealised hint also counts positions with no exchange rate" do
      assert_nil kpi_unrealized_hint(0, 0)
      assert_equal "excludes 1 position with no exchange rate", kpi_unrealized_hint(0, 1)
      assert_equal "excludes 1 position with no cost basis · excludes 2 positions with no exchange rate", kpi_unrealized_hint(1, 2)
    end
  end
end
