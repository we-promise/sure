require "test_helper"

class Import::UploadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @import = imports(:transaction)
  end

  test "show" do
    get import_upload_url(@import)
    assert_response :success
  end

  test "uploads valid csv by copy and pasting" do
    patch import_upload_url(@import), params: {
      import: {
        raw_file_str: file_fixture("imports/valid.csv").read,
        col_sep: ","
      }
    }

    assert_redirected_to import_configuration_url(@import, template_hint: true)
    assert_equal "CSV uploaded successfully.", flash[:notice]
  end

  test "uploads valid csv by file" do
    patch import_upload_url(@import), params: {
      import: {
        import_file: file_fixture_upload("imports/valid.csv"),
        col_sep: ","
      }
    }

    assert_redirected_to import_configuration_url(@import, template_hint: true)
    assert_equal "CSV uploaded successfully.", flash[:notice]
  end

  test "account select does not leak unshared family accounts (#1803)" do
    sign_in users(:family_member)

    get import_upload_url(@import)

    assert_response :success
    assert_match "Checking Account", response.body,
      "Expected the shared account to appear in the account select"
    refute_match "Collectable Account", response.body,
      "Account select must not leak unshared assets to a non-owner family member"
    refute_match "IOU (personal debt to friend)", response.body,
      "Account select must not leak unshared liabilities to a non-owner family member"
    refute_match "Plaid Depository Account", response.body,
      "Account select must not leak unshared connected accounts to a non-owner family member"
  end

  test "invalid csv cannot be uploaded" do
    patch import_upload_url(@import), params: {
      import: {
        import_file: file_fixture_upload("imports/invalid.csv"),
        col_sep: ","
      }
    }

    assert_response :unprocessable_entity
    assert_equal "Must be valid CSV with headers and at least one row of data", flash[:alert]
  end
end
