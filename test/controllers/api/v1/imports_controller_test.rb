# frozen_string_literal: true

require "test_helper"

class Api::V1::ImportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @import = imports(:transaction)

    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")

    @diagnostic_category_name = "Diagnostic Groceries #{SecureRandom.hex(4)}"
    @diagnostic_import = @family.imports.create!(
      type: "TransactionImport",
      status: "pending",
      account: @account,
      raw_file_str: "date,amount,name,category,tags\n01/15/2024,-10.00,Grocery Run,#{@diagnostic_category_name},Food|Weekly",
      date_col_label: "date",
      amount_col_label: "amount",
      name_col_label: "name",
      category_col_label: "category",
      tags_col_label: "tags"
    )
    @diagnostic_row = @diagnostic_import.rows.create!(
      source_row_number: 7,
      date: "01/15/2024",
      amount: "-10.00",
      currency: "USD",
      name: "Grocery Run",
      category: @diagnostic_category_name,
      entity_type: "checking",
      tags: "Food|Weekly"
    )
    @invalid_diagnostic_row = @diagnostic_import.rows.build(
      source_row_number: 8,
      date: "not-a-date",
      amount: "not-a-number",
      currency: "BAD",
      name: "Bad Row"
    )
    @invalid_diagnostic_row.save!(validate: false)

    @diagnostic_category = @family.categories.create!(
      name: @diagnostic_category_name,
      color: "#407706",
      lucide_icon: "shopping-basket"
    )
    Import::CategoryMapping.create!(
      import: @diagnostic_import,
      key: @diagnostic_category_name,
      mappable: @diagnostic_category
    )
    Import::AccountTypeMapping.create!(
      import: @diagnostic_import,
      key: "checking",
      value: "Depository"
    )
  end

  test "should list imports" do
    get api_v1_imports_url, headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_not_empty json_response["data"]
    assert_equal @family.imports.count, json_response["meta"]["total_count"]

    import_data = json_response["data"].detect { |data| data["id"] == @import.id }
    assert_not_nil import_data
    assert_equal @import.uploaded?, import_data["status_detail"]["uploaded"]
    assert_equal @import.configured?, import_data["status_detail"]["configured"]
    assert_equal @import.complete? || @import.failed? || @import.revert_failed?, import_data["status_detail"]["terminal"]
  end

  test "should show import" do
    get api_v1_import_url(@import), headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    rows = @import.rows.to_a
    valid_rows_count = rows.count(&:valid?)
    invalid_rows_count = rows.length - valid_rows_count

    assert_equal @import.id, json_response["data"]["id"]
    assert_equal @import.status, json_response["data"]["status"]
    assert json_response["data"].key?("status_detail")
    assert_equal @import.uploaded?, json_response["data"]["status_detail"]["uploaded"]
    assert_equal @import.configured?, json_response["data"]["status_detail"]["configured"]
    assert_equal @import.cleaned_from_validation_stats?(invalid_rows_count: invalid_rows_count),
                 json_response["data"]["status_detail"]["cleaned"]
    assert_equal @import.publishable_from_validation_stats?(invalid_rows_count: invalid_rows_count),
                 json_response["data"]["status_detail"]["publishable"]
    assert_equal @import.revertable?, json_response["data"]["status_detail"]["revertable"]
    assert_equal @import.rows_count, json_response["data"]["stats"]["rows_count"]
    assert_equal valid_rows_count, json_response["data"]["stats"]["valid_rows_count"]
    assert_equal invalid_rows_count, json_response["data"]["stats"]["invalid_rows_count"]
    assert_equal @import.mappings.count, json_response["data"]["stats"]["mappings_count"]
    assert_equal @import.mappings.where(mappable_id: nil).count,
                 json_response["data"]["stats"]["unassigned_mappings_count"]
  end

  test "should list sanitized import row diagnostics" do
    get rows_api_v1_import_url(@diagnostic_import), headers: api_headers(@read_only_api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal 2, json_response["meta"]["total_count"]
    row_data = json_response["data"].find { |row| row["id"] == @diagnostic_row.id }

    assert_not_nil row_data
    assert_equal true, row_data["valid"]
    assert_equal 7, row_data["row_number"]
    assert_equal "Grocery Run", row_data.dig("fields", "name")
    assert_equal @diagnostic_category_name, row_data.dig("fields", "category")
    assert_equal @diagnostic_category.id, row_data.dig("mappings", "category", "mappable", "id")
    assert_equal "Depository", row_data.dig("mappings", "account_type", "value")
    tag_mapping = row_data.dig("mappings", "tags").find { |mapping| mapping["key"] == "Weekly" }
    assert_not_nil tag_mapping
    assert_nil tag_mapping["value"]
    assert_not row_data.key?("raw_file_str")
    refute_includes response.body, @diagnostic_import.raw_file_str
  end

  test "should include validation errors for invalid import rows" do
    get rows_api_v1_import_url(@diagnostic_import), headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)
    row_data = json_response["data"].find { |row| row["id"] == @invalid_diagnostic_row.id }

    assert_not_nil row_data
    assert_equal false, row_data["valid"]
    assert_not_empty row_data["errors"]
  end

  test "should paginate import row diagnostics" do
    get rows_api_v1_import_url(@diagnostic_import),
        params: { page: 1, per_page: 1 },
        headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal 1, json_response["data"].length
    assert_equal 2, json_response["meta"]["total_count"]
    assert_equal 1, json_response["meta"]["per_page"]
  end

  test "should list import row diagnostics in source row order" do
    @diagnostic_import.rows.create!(
      source_row_number: 6,
      date: "01/14/2024",
      amount: "-5.00",
      currency: "USD",
      name: "Earlier Source Row"
    )

    get rows_api_v1_import_url(@diagnostic_import), headers: api_headers(@api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal [ 6, 7, 8 ], json_response["data"].map { |row| row["row_number"] }
  end

  test "should not expose another family's import rows" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_import = other_family.imports.create!(type: "TransactionImport", raw_file_str: "date,amount,name")

    get rows_api_v1_import_url(other_import), headers: api_headers(@api_key)

    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal "not_found", json_response["error"]
  end

  test "should require authentication for import row diagnostics" do
    get rows_api_v1_import_url(@diagnostic_import)

    assert_response :unauthorized
  end

  test "should require read scope for import row diagnostics" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get rows_api_v1_import_url(@diagnostic_import), headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  test "should create import with raw content" do
    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    json_response = JSON.parse(response.body)
    assert_equal "pending", json_response["data"]["status"]

    created_import = Import.find(json_response["data"]["id"])
    assert_equal csv_content, created_import.raw_file_str
  end

  test "should create import and generate rows when configured" do
    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"

    assert_difference([ "Import.count", "Import::Row.count" ], 1) do
      post api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    json_response = JSON.parse(response.body)

    import = Import.find(json_response["data"]["id"])
    assert_equal 1, import.rows_count
    assert_equal "Test Transaction", import.rows.first.name
    assert_equal "-10.00", import.rows.first.amount # Normalized
  end

  test "should instantiate RuleImport before generating rows" do
    @family.categories.create!(
      name: "Groceries",
      color: "#407706",
      lucide_icon: "shopping-basket"
    )

    csv_content = <<~CSV
      name,resource_type,active,effective_date,conditions,actions
      "Categorize groceries","transaction",true,2024-01-01,"[{""condition_type"":""transaction_name"",""operator"":""like"",""value"":""grocery""}]","[{""action_type"":""set_transaction_category"",""value"":""Groceries""}]"
    CSV

    assert_difference([ "Import.count", "Import::Row.count" ], 1) do
      post api_v1_imports_url,
           params: {
             type: "RuleImport",
             raw_file_content: csv_content,
             col_sep: ","
           },
           headers: api_headers(@api_key)
    end

    assert_response :created

    json_response = JSON.parse(response.body)
    import = Import.find(json_response["data"]["id"])
    row = import.rows.first

    assert_instance_of RuleImport, import
    assert_equal 1, import.rows_count
    assert_equal "Categorize groceries", row.name
    assert_equal "transaction", row.resource_type
    assert_equal true, row.active
    assert_equal "2024-01-01", row.effective_date
    assert_equal '[{"condition_type":"transaction_name","operator":"like","value":"grocery"}]', row.conditions
    assert_equal '[{"action_type":"set_transaction_category","value":"Groceries"}]', row.actions
  end

  test "should create Sure import with raw NDJSON content" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           },
           headers: api_headers(@api_key)
    end

    assert_response :created

    json_response = JSON.parse(response.body)
    import = Import.find(json_response["data"]["id"])

    assert_instance_of SureImport, import
    assert import.ndjson_file.attached?
    assert_equal 1, import.rows_count
    assert_equal "pending", import.status
  end

  test "should require authentication for Sure import" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           }
    end

    assert_response :unauthorized
  end

  test "should reject Sure import with read-only API key" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           },
           headers: api_headers(@read_only_api_key)
    end

    assert_response :forbidden
    json_response = JSON.parse(response.body)
    assert_equal "insufficient_scope", json_response["error"]
  end

  test "should create Sure import with uploaded NDJSON file" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    valid_file = Rack::Test::UploadedFile.new(
      StringIO.new(ndjson_content),
      "application/x-ndjson",
      original_filename: "sure-backup.ndjson"
    )

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             file: valid_file
           },
           headers: api_headers(@api_key)
    end

    assert_response :created

    import = Import.find(JSON.parse(response.body)["data"]["id"])
    assert_instance_of SureImport, import
    assert import.ndjson_file.attached?
    assert_equal 1, import.rows_count
  end

  test "should reject Sure import with no file or raw content" do
    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport"
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "missing_content", json_response["error"]
  end

  test "should reject Sure import uploaded file exceeding max size" do
    test_limit = 1.kilobyte
    large_file = Rack::Test::UploadedFile.new(
      StringIO.new("x" * (test_limit + 1)),
      "application/x-ndjson",
      original_filename: "large.ndjson"
    )

    original_value = SureImport::MAX_NDJSON_SIZE
    SureImport.send(:remove_const, :MAX_NDJSON_SIZE)
    SureImport.const_set(:MAX_NDJSON_SIZE, test_limit)

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             file: large_file
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "file_too_large", json_response["error"]
  ensure
    SureImport.send(:remove_const, :MAX_NDJSON_SIZE)
    SureImport.const_set(:MAX_NDJSON_SIZE, original_value)
  end

  test "should reject Sure import uploaded file with invalid type" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    invalid_file = Rack::Test::UploadedFile.new(
      StringIO.new(ndjson_content),
      "application/pdf",
      original_filename: "sure-backup.pdf"
    )

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             file: invalid_file
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "invalid_file_type", json_response["error"]
  end

  test "should clean up Sure import if row sync fails" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    SureImport.any_instance.stubs(:sync_ndjson_rows_count!).raises(StandardError, "sync failed")

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           },
           headers: api_headers(@api_key)
    end

    assert_response :internal_server_error
    json_response = JSON.parse(response.body)
    assert_equal "internal_server_error", json_response["error"]
  end

  test "should clean up Sure import if row sync validation fails" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    invalid_import = SureImport.new
    invalid_import.errors.add(:base, "invalid rows")
    SureImport.any_instance.stubs(:sync_ndjson_rows_count!).raises(ActiveRecord::RecordInvalid.new(invalid_import))

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "validation_failed", json_response["error"]
    assert_includes json_response["errors"], "invalid rows"
  end

  test "should preserve Sure import if publish queueing fails" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    ImportJob.stubs(:perform_later).raises(StandardError, "queue offline")

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content,
             publish: "true"
           },
           headers: api_headers(@api_key)
    end

    assert_response :internal_server_error
    json_response = JSON.parse(response.body)
    assert_equal "publish_failed", json_response["error"]

    import = Import.find(json_response["import_id"])
    assert_instance_of SureImport, import
    assert import.ndjson_file.attached?
    assert_equal 1, import.rows_count
    assert_equal "pending", import.status
  end

  test "should preserve Sure import if auto publish exceeds row count" do
    ndjson_content = { type: "Account", data: { id: "account_1", name: "Checking" } }.to_json
    SureImport.any_instance.stubs(:publish_later).raises(Import::MaxRowCountExceededError)

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: ndjson_content,
             publish: "true"
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "max_row_count_exceeded", json_response["error"]

    import = Import.find(json_response["import_id"])
    assert_instance_of SureImport, import
    assert import.ndjson_file.attached?
    assert_equal 1, import.rows_count
  end

  test "should reject invalid Sure import NDJSON content" do
    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             type: "SureImport",
             raw_file_content: "not ndjson"
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "invalid_ndjson", json_response["error"]
  end

  test "should create import and auto-publish when configured and requested" do
    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"

    assert_enqueued_with(job: ImportJob) do
      post api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id,
             date_format: "%Y-%m-%d",
             publish: "true"
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    json_response = JSON.parse(response.body)
    assert_equal "importing", json_response["data"]["status"]
  end

  test "should not create import for account in another family" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_depository = Depository.create!(subtype: "checking")
    other_account = Account.create!(family: other_family, name: "Other Account", currency: "USD", classification: "asset", accountable: other_depository, balance: 0)

    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"

    post api_v1_imports_url,
          params: {
            raw_file_content: csv_content,
            account_id: other_account.id
          },
          headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_includes json_response["errors"], "Account must belong to your family"
  end

  test "should reject file upload exceeding max size" do
    large_file = Rack::Test::UploadedFile.new(
      StringIO.new("x" * (Import::MAX_CSV_SIZE + 1)),
      "text/csv",
      original_filename: "large.csv"
    )

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: { file: large_file },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "file_too_large", json_response["error"]
  end

  test "should reject file upload with invalid mime type" do
    invalid_file = Rack::Test::UploadedFile.new(
      StringIO.new("not a csv"),
      "application/pdf",
      original_filename: "document.pdf"
    )

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: { file: invalid_file },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "invalid_file_type", json_response["error"]
  end

  test "should reject raw content exceeding max size" do
    # Use a small test limit to avoid Rack request size limits
    test_limit = 1.kilobyte
    large_content = "x" * (test_limit + 1)

    original_value = Import::MAX_CSV_SIZE
    Import.send(:remove_const, :MAX_CSV_SIZE)
    Import.const_set(:MAX_CSV_SIZE, test_limit)

    assert_no_difference("Import.count") do
      post api_v1_imports_url,
           params: { raw_file_content: large_content },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "content_too_large", json_response["error"]
  ensure
    Import.send(:remove_const, :MAX_CSV_SIZE)
    Import.const_set(:MAX_CSV_SIZE, original_value)
  end

  test "should create import with external_id_col_label and generate rows with external_id" do
    csv_content = "date,amount,name,ext_id\n01/01/2024,10.00,Test Transaction,txn-uuid-123"

    assert_difference([ "Import.count", "Import::Row.count" ], 1) do
      post api_v1_imports_url,
           params: {
             raw_file_content: csv_content,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             external_id_col_label: "ext_id",
             account_id: @account.id
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    json_response = JSON.parse(response.body)

    import = Import.find(json_response["data"]["id"])
    assert_equal "ext_id", import.external_id_col_label
    assert_equal "txn-uuid-123", import.rows.first.external_id
  end

  test "should accept file upload with valid csv mime type" do
    csv_content = "date,amount,name\n2023-01-01,-10.00,Test Transaction"
    valid_file = Rack::Test::UploadedFile.new(
      StringIO.new(csv_content),
      "text/csv",
      original_filename: "transactions.csv"
    )

    assert_difference("Import.count") do
      post api_v1_imports_url,
           params: {
             file: valid_file,
             date_col_label: "date",
             amount_col_label: "amount",
             name_col_label: "name",
             account_id: @account.id
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
