require "test_helper"

class Import::MappingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)

    @import = imports(:transaction)
  end

  test "updates mapping" do
    mapping = import_mappings(:one)
    new_category = categories(:income)

    patch import_mapping_path(@import, mapping), params: {
      import_mapping: {
        mappable_type: "Category",
        mappable_id: new_category.id,
        key: "Food"
      }
    }

    mapping.reload

    assert_equal new_category, mapping.mappable
    assert_equal "Food", mapping.key

    assert_redirected_to import_confirm_path(@import)
  end

  # mappable_type and type reach `constantize` straight from request params,
  # so any constant in the app can be resolved and have class methods called
  # on it. Only the mapping types the importer actually uses are allowed.
  test "ignores a mappable_type that is not an importable mapping target" do
    mapping = import_mappings(:one)

    assert_nothing_raised do
      patch import_mapping_path(@import, mapping), params: {
        import_mapping: {
          mappable_type: "User",
          mappable_id: users(:family_admin).id,
          key: "Food"
        }
      }
    end

    assert_redirected_to import_confirm_path(@import)
    assert_nil mapping.reload.mappable
  end

  test "ignores a mapping type that is not an importable mapping class" do
    mapping = import_mappings(:one)

    assert_nothing_raised do
      patch import_mapping_path(@import, mapping), params: {
        import_mapping: {
          type: "Family",
          mappable_type: "Category",
          mappable_id: categories(:income).id,
          key: "Food"
        }
      }
    end

    assert_redirected_to import_confirm_path(@import)
  end

  test "marks the mapping for creation when the picker asks for a new resource" do
    mapping = import_mappings(:one)

    patch import_mapping_path(@import, mapping), params: {
      import_mapping: {
        mappable_type: "Category",
        mappable_id: Import::Mapping::CREATE_NEW_KEY,
        key: "Food"
      }
    }

    mapping.reload
    assert mapping.create_when_empty, "the create-new sentinel must still set create_when_empty"
    assert_nil mapping.mappable
  end
end
