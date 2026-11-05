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

  test "re-importing a Sure transactions.csv export keeps transfer directions" do
    family = @user.family
    source = family.accounts.create!(name: "Export Source", accountable: Depository.new, balance: 1000, currency: "USD")
    destination = family.accounts.create!(name: "Export Destination", accountable: Depository.new, balance: 0, currency: "USD")
    outflow = source.entries.create!(name: "Transfer to savings", date: Date.parse("2024-05-17"), amount: 100, currency: "USD", entryable: Transaction.new(kind: "funds_movement"))
    inflow = destination.entries.create!(name: "Transfer from checking", date: Date.parse("2024-05-17"), amount: -100, currency: "USD", entryable: Transaction.new(kind: "funds_movement"))
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable, status: "confirmed")

    exported_csv = nil
    Zip::File.open_buffer(Family::DataExporter.new(family).generate_export) do |zip|
      exported_csv = zip.read("transactions.csv")
    end

    patch import_upload_url(@import), params: { import: { raw_file_str: exported_csv, col_sep: "," } }

    get import_configuration_url(@import)
    assert_select 'select[name="import[signage_convention]"] option[selected][value="inflows_negative"]'
    assert_select 'select[name="import[date_format]"] option[selected][value="%Y-%m-%d"]'

    # Submit the column mapping and keep every preselected setting, as the form does
    @import.reload
    patch import_configuration_url(@import), params: {
      import: {
        date_col_label: "date",
        date_format: @import.date_format,
        amount_col_label: "amount",
        number_format: @import.number_format,
        amount_type_strategy: @import.amount_type_strategy,
        signage_convention: @import.signage_convention,
        account_col_label: "account_name",
        name_col_label: "name",
        currency_col_label: "currency"
      }
    }

    rows = @import.reload.rows
    assert_equal outflow.amount, rows.find_by!(name: outflow.name, account: source.name).signed_amount
    assert_equal inflow.amount, rows.find_by!(name: inflow.name, account: destination.name).signed_amount
  end

  test "account select does not leak unshared family accounts (#1803)" do
    sign_in users(:family_member)

    get import_upload_url(@import)

    assert_response :success
    assert_select 'select[name="import[account_id]"] option', text: "Checking Account"
    assert_select 'select[name="import[account_id]"] option', text: "Collectable Account", count: 0
    assert_select 'select[name="import[account_id]"] option', text: "IOU (personal debt to friend)", count: 0
    assert_select 'select[name="import[account_id]"] option', text: "Plaid Depository Account", count: 0
  end

  test "respects SURE_IMPORT_MAX_NDJSON_SIZE_MB when uploading Sure import file (#3010)" do
    configured_limit = 2.megabytes
    SureImport.stubs(:max_ndjson_size).returns(configured_limit)

    sure_import = imports(:sure)
    oversized_file = Rack::Test::UploadedFile.new(
      StringIO.new("x" * (configured_limit + 1)),
      "application/x-ndjson",
      original_filename: "all.ndjson"
    )

    patch import_upload_url(sure_import), params: {
      import: { ndjson_file: oversized_file }
    }

    assert_response :unprocessable_entity
    assert_equal I18n.t("imports.create.file_too_large", max_size: configured_limit / 1.megabyte), flash[:alert]
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
