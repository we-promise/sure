require "application_system_test_case"

class IcostImportsTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "uploads an XLSX for review and opens the local map" do
    visit new_icost_import_path
    attach_file "icost_import_files", Rails.root.join("test/fixtures/files/imports/icost.xlsx")
    uncheck "icost_import_auto_post"
    click_button I18n.t("icost_imports.prepare")

    assert_text "Synthetic category"
    assert_selector "[data-icost-count]", count: 5
    batch = users(:family_admin).family.icost_imports.last
    assert_equal 1, batch.records.count
    click_link "2", href: icost_import_record_path(batch, batch.records.sole)
    assert_text "Synthetic museum"

    visit icost_map_path
    click_button I18n.t("icost_maps.load")
    assert_selector ".leaflet-container"
  end
end
