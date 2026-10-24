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

  test "updating a security mapping with a combobox value resolves and assigns the mappable" do
    trade_import = imports(:trade)
    mapping = trade_import.mappings.build(key: "MICROSOFT CORP", type: "Import::SecurityMapping")
    mapping.save!(validate: false) # unresolved mappings persist without a mappable, as sync_mappings does
    msft = securities(:msft)

    resolver = mock
    resolver.stubs(:resolve).returns(msft)
    Security::Resolver.stubs(:new).returns(resolver)

    patch import_mapping_path(trade_import, mapping), params: {
      import_mapping: {
        type: "Import::SecurityMapping",
        key: "MICROSOFT CORP",
        value: "MSFT|XNAS|"
      }
    }

    mapping.reload

    assert_equal "MSFT|XNAS|", mapping.value
    assert_equal msft, mapping.mappable
    assert_redirected_to import_confirm_path(trade_import)
  end

  test "clearing a descriptive-label security selection succeeds and drops the mappable" do
    trade_import = imports(:trade)
    mapping = trade_import.mappings.build(
      key: "MICROSOFT CORP",
      type: "Import::SecurityMapping",
      mappable: securities(:msft)
    )
    mapping.save!(validate: false)

    patch import_mapping_path(trade_import, mapping), params: {
      import_mapping: { type: "Import::SecurityMapping", key: "MICROSOFT CORP", value: "" }
    }

    mapping.reload

    assert_nil mapping.mappable, "clearing must drop the stale security"
    assert_redirected_to import_confirm_path(trade_import)
  end
end
