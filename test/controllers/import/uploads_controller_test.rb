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

  test "sample_csv sends a CSV template for CSV imports" do
    get import_upload_sample_csv_url(@import)

    assert_response :success
    assert_equal "text/csv", response.media_type
  end

  [ PdfImport, QifImport, MonarchImport, SureImport ].each do |import_type|
    test "sample_csv redirects for #{import_type} without a CSV template" do
      import = import_type.create!(family: @user.family)

      get import_upload_sample_csv_url(import)

      assert_redirected_to import_upload_url(import)
      assert_equal "A sample CSV is not available for this import type.", flash[:alert]
    end
  end

  test "a published Sure import's file can't be swapped while it runs" do
    sign_in member = users(:family_member)
    import = @user.family.imports.create!(type: "SureImport")
    import.ndjson_file.attach(io: StringIO.new({ type: "Tag", data: { id: "tag-1", name: "Harmless" } }.to_json), filename: "all.ndjson", content_type: "application/x-ndjson")
    import.publish_later(user: member)
    original = import.reload.ndjson_file.blob.id

    rule = { type: "Rule", data: { id: "rule-1", name: "Swapped", resource_type: "transaction", active: true, actions: [ { action_type: "exclude_transaction" } ] } }
    patch import_upload_url(import), params: { import: { ndjson_file: Rack::Test::UploadedFile.new(StringIO.new(rule.to_json), "application/x-ndjson", original_filename: "all.ndjson") } }

    assert_redirected_to import_path(import)
    assert_equal I18n.t("imports.published_locked"), flash[:alert]
    assert_equal original, import.reload.ndjson_file.blob.id
  end

  test "a published CSV import's account can't be changed while it runs" do
    sign_in member = users(:family_member)
    @import.update!(account: accounts(:depository))
    TransactionImport.any_instance.stubs(:publishable?).returns(true)
    @import.publish_later(user: member)

    patch import_upload_url(@import), params: { import: { raw_file_str: file_fixture("imports/valid.csv").read, col_sep: ",", account_id: accounts(:credit_card).id } }

    assert_redirected_to import_path(@import)
    assert_equal accounts(:depository), @import.reload.account
  end

  test "an import session's chunk can't be changed or listed in the web wizard" do
    sign_in users(:family_member)
    session = @user.family.import_sessions.create!(created_by: @user, status: :importing)
    chunk = session.imports.create!(family: @user.family, type: "SureImport", sequence: 1, checksum: "0" * 64)
    chunk.ndjson_file.attach(io: StringIO.new({ type: "Tag", data: { id: "tag-1", name: "Harmless" } }.to_json), filename: "all.ndjson", content_type: "application/x-ndjson")
    original = chunk.ndjson_file.blob.id

    rule = { type: "Rule", data: { id: "rule-1", name: "Swapped", resource_type: "transaction", active: true, actions: [ { action_type: "exclude_transaction" } ] } }
    patch import_upload_url(chunk), params: { import: { ndjson_file: Rack::Test::UploadedFile.new(StringIO.new(rule.to_json), "application/x-ndjson", original_filename: "all.ndjson") } }

    assert_redirected_to import_path(chunk)
    assert_equal original, chunk.reload.ndjson_file.blob.id

    get imports_url
    assert_not_includes response.body, import_path(chunk)
  end

  test "the new import page doesn't offer an import session's chunk to resume" do
    session = @user.family.import_sessions.create!(created_by: @user)
    chunk = session.imports.create!(family: @user.family, type: "SureImport", sequence: 1, checksum: "0" * 64)
    @user.family.imports.where.not(id: chunk.id).update_all(status: "complete")

    get new_import_url

    assert_not_includes response.body, import_path(chunk)
  end

  test "a change while the import is being published asks to try again" do
    Import.any_instance.stubs(:with_publish_lock).raises(Import::PublishBusyError)

    patch import_upload_url(@import), params: { import: { raw_file_str: file_fixture("imports/valid.csv").read, col_sep: "," } }

    assert_redirected_to import_path(@import)
    assert_equal I18n.t("imports.publish_busy"), flash[:alert]
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

  # handle_qif_upload runs inside the update action, so its lazy `t(".…")`
  # lookups resolve under import.uploads.update.
  test "a QIF file without an account asks for one" do
    import = QifImport.create!(family: @user.family)

    patch import_upload_url(import), params: {
      import: { raw_file_str: "!Type:Bank\nD01/15/2024\nT-12.50\nPCoffee\n^\n" }
    }

    assert_response :unprocessable_entity
    assert_equal "Please select an account for the QIF import", flash[:alert]
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
