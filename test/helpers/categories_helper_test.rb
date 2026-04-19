require "test_helper"

class CategoriesHelperTest < ActionView::TestCase
  include CategoriesHelper

  setup do
    @family = families(:dylan_family)
    Current.stubs(:family).returns(@family)
  end

  test "family_categories prepends Uncategorized and sorts alphabetically" do
    categories = family_categories

    assert_equal "Uncategorized", categories.first.name
    assert categories.length > 1

    # Everything after Uncategorized is plain alphabetical.
    rest = categories.drop(1).map(&:name)
    assert_equal rest.sort, rest
  end

  test "family_categories_with_hierarchy prepends Uncategorized and orders parents before their children" do
    categories = family_categories_with_hierarchy

    assert_equal "Uncategorized", categories.first.name
    assert categories.length > 1

    rest = categories.drop(1)
    rest.each_with_index do |category, index|
      next unless category.subcategory?
      # Parent of each subcategory must appear earlier in the list, so
      # consumers (the filter sidebar) can apply a hanging indent without
      # reshuffling.
      parent_index = rest.find_index { |c| c.id == category.parent_id }
      assert parent_index, "Parent of '#{category.name}' should be in the list"
      assert parent_index < index,
        "Parent '#{category.parent&.name}' should appear before subcategory '#{category.name}'"
    end
  end
end
