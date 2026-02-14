require "test_helper"

class CategoryTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
  end

  test "replacing and destroying" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(categories(:income))

    assert_equal categories(:income), transactions.map { |t| t.reload.category }.uniq.first
  end

  test "replacing with nil should nullify the category" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(nil)

    assert_nil transactions.map { |t| t.reload.category }.uniq.first
  end

  test "subcategory can only be one level deep" do
    category = categories(:subcategory)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      category.subcategories.create!(name: "Invalid category", family: @family)
    end

    assert_equal "Validation failed: Parent can't have more than 2 levels of subcategories", error.message
  end

  test "name_with_indent returns name for root category" do
    category = categories(:food_and_drink)
    assert_equal "Food & Drink", category.name_with_indent
  end

  test "name_with_indent returns indented name for subcategory" do
    category = categories(:subcategory)
    # Uses non-breaking spaces (U+00A0) for HTML-safe indentation
    assert_equal "\u00A0\u00A0\u00A0\u00A0Restaurants", category.name_with_indent
  end

  test "alphabetically_by_hierarchy orders parents before their children" do
    parent = categories(:food_and_drink)
    child = categories(:subcategory)

    ordered = @family.categories.alphabetically_by_hierarchy.to_a
    parent_index = ordered.index(parent)
    child_index = ordered.index(child)

    assert parent_index < child_index, "Parent should come before child in hierarchy order"
  end
end
