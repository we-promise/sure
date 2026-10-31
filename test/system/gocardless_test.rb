require "application_system_test_case"

class GocardlessTest < ApplicationSystemTestCase
  setup do
    families(:dylan_family).gocardless_items.create!(name: "Test bank", secret_id: "test-id", secret_key: "test-key")
    Provider::Gocardless.any_instance.stubs(:get_institutions).returns([
      { id: "TEST_BANK", name: "Test Bank", bic: "TESTGB", transaction_total_days: 730 },
      { id: "SECOND_BANK", name: "Second Bank", bic: "SECONDGB", transaction_total_days: 90 }
    ])
    sign_in users(:family_admin)
  end

  test "bank picker displays and searches institutions" do
    visit new_gocardless_item_path
    assert_text "Test Bank"
    assert_text "Second Bank"
    find('input[data-bank-search-target="input"]').set("TESTGB")
    assert_text "Test Bank"
    assert_no_text "Second Bank"
    page.save_screenshot(Rails.root.join("tmp/screenshots/gocardless-bank-picker.png"))
  end
end
