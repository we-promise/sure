require "test_helper"
require "zip"

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

  test "uploads sure export zip and stores ndjson" do
    sure_import = @user.family.imports.create!(type: "SureImport")

    patch import_upload_url(sure_import), params: {
      import: {
        ndjson_file: build_sure_export_zip_upload
      }
    }

    assert_redirected_to import_url(sure_import)
    assert_equal I18n.t("imports.create.ndjson_uploaded"), flash[:notice]
    assert sure_import.reload.ndjson_file.attached?
    assert_equal "all.ndjson", sure_import.ndjson_file.filename.to_s
  end

  private
    def build_sure_export_zip_upload
      ndjson = { type: "Account", data: { id: "uuid-zip", name: "Zip Upload Account", balance: "10", currency: "USD", accountable_type: "Depository" } }.to_json

      buffer = Zip::OutputStream.write_buffer do |zip|
        zip.put_next_entry("all.ndjson")
        zip.write(ndjson)
      end
      buffer.rewind

      Rack::Test::UploadedFile.new(
        StringIO.new(buffer.read),
        "application/zip",
        original_filename: "data-export.zip"
      )
    end
end
