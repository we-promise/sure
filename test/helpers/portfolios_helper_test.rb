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

  test "allocation colours come from the shared chart palette and wrap around" do
    assert_equal Category::COLORS.first, allocation_color(0)
    assert_equal Category::COLORS.first, allocation_color(Category::COLORS.size)
    assert_equal Category::COLORS.last, allocation_color(Category::COLORS.size - 1)
  end

  test "allocation segments serialise to the donut chart's contract" do
    segment = InvestmentStatement.const_get(:AllocationSegment).new(id: "USD", name: "USD", amount: Money.new(1234.567, "USD"), weight: 61.234)

    json = JSON.parse(allocation_segments_json([ segment ], currency: "USD"))

    assert_equal [ { "id" => "USD", "name" => "USD", "amount" => 1234.57, "currency" => "USD", "percentage" => 61.2, "color" => Category::COLORS.first } ], json
  end

  test "a segment's label is translated in its grouping's vocabulary, by id for unclassified" do
    segment = ->(id, name = id) { InvestmentStatement.const_get(:AllocationSegment).new(id: id, name: name, amount: Money.new(1, "USD"), weight: 1) }

    assert_equal I18n.t("portfolios.allocation.kinds.standard"), allocation_segment_name(segment.call("standard"), "kind")
    assert_equal I18n.t("portfolios.allocation.asset_classes.equity"), allocation_segment_name(segment.call("equity"), "asset_class")
    assert_equal I18n.t("portfolios.allocation.unclassified"), allocation_segment_name(segment.call(InvestmentStatement::UNCLASSIFIED), "sector")
    assert_equal "Technology", allocation_segment_name(segment.call("Technology"), "sector"), "provider free text is shown as it comes"
    assert_equal "unclassified", allocation_segment_name(segment.call("sec-1", "unclassified"), "security"),
      "a security named unclassified keeps its own name"
    assert_equal "mars", allocation_segment_name(segment.call("mars"), "region"), "an unknown region shows its value, not a missing translation"
  end

  test "a sub-class below an asset class is limited to that class; other levels carry the parent" do
    segment = InvestmentStatement.const_get(:AllocationSegment).new(id: "equity", name: "equity", amount: Money.new(1, "USD"), weight: 1)

    assert_equal "asset_sub_class", allocation_child_grouping("asset_class")
    assert_equal "security", allocation_child_grouping("asset_sub_class")
    assert_equal "equity", allocation_child_parent("asset_class", segment, nil)
    assert_equal "liquidity", allocation_child_parent("asset_sub_class", segment, "liquidity")
    assert_nil allocation_child_parent("asset_sub_class", segment, nil)
  end
end
