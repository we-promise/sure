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

  # The form submits `mappable_type`/`type` as hidden fields, so a client can change them.
  # They used to be resolved with `constantize` and used for the lookup, which let a request
  # point a Category mapping at any model exposing a `family` association. The mapping's own
  # type governs now, so a tampered `mappable_type` cannot redirect the lookup.
  test "ignores client supplied mappable_type when resolving the mapping" do
    mapping = import_mappings(:one)
    other_user = users(:family_member)

    assert_equal "Import::CategoryMapping", mapping.type

    patch import_mapping_path(@import, mapping), params: {
      import_mapping: {
        mappable_type: "User",
        mappable_id: other_user.id
      }
    }

    mapping.reload

    assert_nil mapping.mappable
    assert_not_equal "User", mapping.mappable_type
  end
end
