require "test_helper"

class Reports::CategorySelectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @parent = categories(:food_and_drink)
    @child = categories(:subcategory)
  end

  test "a blank selection is inactive" do
    selection = Reports::CategorySelection.new(@family, [])

    assert_not selection.active?
    assert_empty selection.group_values
    assert_equal 0, selection.selected_count
  end

  test "accepts a single id as a string" do
    selection = Reports::CategorySelection.new(@family, @parent.id.to_s)

    assert selection.active?
    assert_equal [ @parent.id.to_s ], selection.selected_values
  end

  test "a parent selection checks its subcategories" do
    selection = Reports::CategorySelection.new(@family, [ @parent.id.to_s ])
    option = selection.options.find { |entry| entry.category.id == @child.id }

    assert option.checked
    assert_equal [ @parent.id.to_s ], selection.group_values
    assert_equal 1, selection.selected_count
  end

  test "a child inherits checked state from its selected parent" do
    selection = Reports::CategorySelection.new(@family, [ @parent.id.to_s ])
    child_option = selection.options.find { |entry| entry.category.id == @child.id }

    assert child_option.checked
  end

  test "a selected child without its parent stays its own line" do
    selection = Reports::CategorySelection.new(@family, [ @child.id.to_s ])

    assert_equal [ @child.id.to_s ], selection.group_values
    assert_equal 1, selection.selected_count
  end

  test "the uncategorized sentinel is kept and never treated as an id" do
    selection = Reports::CategorySelection.new(@family, [ Category::UNCATEGORIZED_FILTER_VALUE ])

    assert selection.active?
    assert_equal [ Category::UNCATEGORIZED_FILTER_VALUE ], selection.group_values
    assert_equal 1, selection.selected_count
  end

  test "ids from another family are ignored" do
    foreign = Category.create!(family: families(:empty), name: "Foreign report category",
                               color: "#123456", lucide_icon: "shapes")
    selection = Reports::CategorySelection.new(@family, [ foreign.id.to_s ])

    assert_not selection.active?
    assert_empty selection.group_values
  end

  test "malformed params are ignored" do
    selection = Reports::CategorySelection.new(@family, { "bad" => "shape" })

    assert_not selection.active?
    assert_empty selection.selected_values
  end
end
