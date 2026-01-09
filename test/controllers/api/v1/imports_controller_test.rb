require "test_helper"

class Api::V1::ImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = accounts(:depository)
    @import = imports(:transaction)
    @token = valid_token_for(@user)
  end

  test "should list imports" do
    get api_v1_imports_url, headers: { Authorization: "Bearer #{@token}" }
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_not_empty json_response["data"]
    assert_equal @family.imports.count, json_response["meta"]["total_count"]
  end

  test "should show import" do
    get api_v1_import_url(@import), headers: { Authorization: "Bearer #{@token}" }
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal @import.id, json_response["data"]["id"]
    assert_equal @import.status, json_response["data"]["status"]
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
           headers: { Authorization: "Bearer #{@token}" }
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
           headers: { Authorization: "Bearer #{@token}" }
    end

    assert_response :created
    json_response = JSON.parse(response.body)

    import = Import.find(json_response["data"]["id"])
    assert_equal 1, import.rows_count
    assert_equal "Test Transaction", import.rows.first.name
    assert_equal "-10.00", import.rows.first.amount # Normalized
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
           headers: { Authorization: "Bearer #{@token}" }
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
          headers: { Authorization: "Bearer #{@token}" }

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
           headers: { Authorization: "Bearer #{@token}" }
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
           headers: { Authorization: "Bearer #{@token}" }
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
           headers: { Authorization: "Bearer #{@token}" }
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "content_too_large", json_response["error"]
  ensure
    Import.send(:remove_const, :MAX_CSV_SIZE)
    Import.const_set(:MAX_CSV_SIZE, original_value)
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
           headers: { Authorization: "Bearer #{@token}" }
    end

    assert_response :created
  end

  private

    def valid_token_for(user)
      application = Doorkeeper::Application.create!(name: "Test App", redirect_uri: "urn:ietf:wg:oauth:2.0:oob", scopes: "read read_write")
      Doorkeeper::AccessToken.create!(application: application, resource_owner_id: user.id, scopes: "read read_write").token
    end
end
