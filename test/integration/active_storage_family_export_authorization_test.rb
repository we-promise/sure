require "test_helper"

# Family exports hold the whole family's data; the blob routes release them to family admins only.
class ActiveStorageFamilyExportAuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @export = @admin.family.family_exports.create!(status: :completed)
    @export.export_file.attach(io: StringIO.new("zip"), filename: "export.zip", content_type: "application/zip")
  end

  test "family admin can download their family export" do
    sign_in @admin
    get rails_blob_path(@export.export_file)

    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "user from another family cannot download the family export" do
    sign_in users(:empty)
    get rails_blob_path(@export.export_file)

    assert_response :not_found
  end

  test "non-admin family member cannot download the family export" do
    sign_in users(:family_member)
    get rails_blob_path(@export.export_file)

    assert_response :not_found
  end
end
