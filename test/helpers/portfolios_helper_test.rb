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
end
