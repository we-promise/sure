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

  test "account mapping lists connected accounts as targets" do
    @import.update!(
      raw_file_str: <<~CSV,
        date,amount,account
        #{Date.current.iso8601},25,Imported Checking
      CSV
      date_col_label: "date",
      amount_col_label: "amount",
      account_col_label: "account",
      date_format: "%Y-%m-%d"
    )
    @import.generate_rows_from_csv
    @import.sync_mappings

    get import_confirm_path(@import, step: 3)

    assert_response :success
    assert_select "select option[value='#{accounts(:connected).id}']", text: "Plaid Depository Account"
  end

  test "account mapping excludes accounts the user cannot write" do
    sign_in users(:family_member)

    @import.update!(
      raw_file_str: <<~CSV,
        date,amount,account
        #{Date.current.iso8601},25,Credit Card
      CSV
      date_col_label: "date",
      amount_col_label: "amount",
      account_col_label: "account",
      date_format: "%Y-%m-%d"
    )
    @import.generate_rows_from_csv
    @import.sync_mappings

    get import_confirm_path(@import, step: 3)

    assert_response :success
    assert_select "select option", text: "Add as new account"
    assert_select "select option", text: "Credit Card", count: 0
  end
end
