require "test_helper"

class Import::CategoryMappingTest < ActiveSupport::TestCase
  setup do
    @mapping = import_mappings(:one)
  end

  test "selectable_values groups subcategories immediately after their parent" do
    options = @mapping.selectable_values

    parent_index = options.index { |_label, id| id == categories(:food_and_drink).id }
    child_index = options.index { |_label, id| id == categories(:subcategory).id }

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index
  end

  test "selectable_values still prepends 'Add as new category' when key is present" do
    options = @mapping.selectable_values

    assert_equal "Add as new category", options.first.first
    assert_equal Import::Mapping::CREATE_NEW_KEY, options.first.last
  end
end
