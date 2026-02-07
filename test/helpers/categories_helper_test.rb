require "test_helper"

class CategoriesHelperTest < ActionView::TestCase
  include CategoriesHelper

  setup do
    @family = families(:dylan_family)
    Current.stubs(:family).returns(@family)
  end

  test "family_categories returns uncategorized plus alphabetically sorted categories" do
    categories = family_categories

    assert_equal "Uncategorized", categories.first.name
    assert categories.length > 1

    # Rest should be alphabetically sorted (excluding uncategorized)
    category_names = categories.drop(1).map(&:name)
    assert_equal category_names.sort, category_names
  end

  test "family_categories_with_hierarchy returns uncategorized plus hierarchically sorted categories" do
    categories = family_categories_with_hierarchy

    assert_equal "Uncategorized", categories.first.name
    assert categories.length > 1

    # Subcategories should appear after their parents
    categories.drop(1).each_with_index do |category, index|
      if category.subcategory?
        # Find parent in the list
        parent_index = categories.drop(1).find_index { |c| c.id == category.parent_id }
        assert parent_index, "Parent category should exist in the list"
        assert parent_index < index, "Parent (#{category.parent&.name}) should appear before subcategory (#{category.name})"
      end
    end
  end
end
