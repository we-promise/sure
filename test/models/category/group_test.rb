require "test_helper"

class Category::GroupTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "for groups categories by parent, root categories without children get an empty subcategories array" do
    groups = Category::Group.for(@family.categories)

    food_group = groups.find { |g| g.category == categories(:food_and_drink) }
    assert_equal [ categories(:subcategory) ], food_group.subcategories

    income_group = groups.find { |g| g.category == categories(:income) }
    assert_equal [], income_group.subcategories
  end

  test "for does not include a category as its own root when it is a subcategory" do
    groups = Category::Group.for(@family.categories)

    assert_nil groups.find { |g| g.category == categories(:subcategory) }
  end

  test "select_options orders parent immediately followed by its children" do
    options = Category::Group.select_options(@family.categories)

    parent_index = options.index { |label, id| id == categories(:food_and_drink).id }
    child_index = options.index { |label, id| id == categories(:subcategory).id }

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index, "subcategory should immediately follow its parent in the options list"
  end

  test "select_options indents subcategory labels so they're visually distinguishable from parents" do
    options = Category::Group.select_options(@family.categories)

    parent_label, = options.find { |label, id| id == categories(:food_and_drink).id }
    child_label, = options.find { |label, id| id == categories(:subcategory).id }

    assert_equal categories(:food_and_drink).name, parent_label
    assert_equal "↳ #{categories(:subcategory).name}", child_label
  end

  test "select_options orders roots and subcategories alphabetically regardless of input order" do
    reversed_options = Category::Group.select_options(@family.categories.to_a.reverse)
    forward_options = Category::Group.select_options(@family.categories)

    assert_equal forward_options, reversed_options
  end

  test "select_options returns [label, id] pairs usable directly by options_for_select / form.select" do
    options = Category::Group.select_options(@family.categories)

    assert options.all? { |pair| pair.is_a?(Array) && pair.size == 2 }
    assert options.all? { |_label, id| id.present? }
  end
end
