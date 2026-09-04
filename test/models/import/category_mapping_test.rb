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

  test "create_mappable! uses root parent when parent_name matches an existing subcategory" do
    import = @mapping.import

    # First, create a mapping where "Insurance" becomes a subcategory under "Auto"
    m1 = import.mappings.create!(key: "Auto:Insurance", create_when_empty: true, type: "Import::CategoryMapping")
    m1.create_mappable!

    insurance_sub = import.family.categories.find_by!(name: "Insurance")
    assert insurance_sub.subcategory?
    assert_equal "Auto", insurance_sub.parent.name

    # Now create a mapping where "Insurance" is the parent_name in "Insurance:ADD"
    m2 = import.mappings.create!(key: "Insurance:ADD", create_when_empty: true, type: "Import::CategoryMapping")
    assert_nothing_raised do
      m2.create_mappable!
    end

    add_sub = import.family.categories.find_by!(name: "ADD")
    assert add_sub.subcategory?
    assert_equal "Auto", add_sub.parent.name
  end
end
