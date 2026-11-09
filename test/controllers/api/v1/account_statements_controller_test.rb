# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountStatementsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family = @admin.family
    @account = accounts(:depository)

    @admin.api_keys.active.destroy_all
    @member.api_keys.active.destroy_all

    @api_key = create_api_key(@admin, "read_write")
    @read_only_api_key = create_api_key(@admin, "read")
    @member_api_key = create_api_key(@member, "read_write")
  end

  teardown do
    redis = Redis.new
    [ @api_key, @read_only_api_key, @member_api_key, @guest_api_key ].compact.each do |key|
      redis.del("api_rate_limit:#{key.id}")
    end
    redis.close
  end

  test "requires authentication" do
    get api_v1_account_statements_url
    assert_response :unauthorized

    post api_v1_account_statements_url, params: { file: statement_upload }
    assert_response :unauthorized
  end

  test "uploads a statement linked to an account without importing transactions" do
    assert_difference "AccountStatement.count", 1 do
      assert_no_difference [ "Import.count", "Entry.count" ] do
        post api_v1_account_statements_url,
             params: { file: statement_upload, account_id: @account.id },
             headers: api_headers(@api_key)
      end
    end

    assert_response :created
    body = JSON.parse(response.body)
    statement = AccountStatement.find(body["data"]["id"])

    assert_equal @account, statement.account
    assert statement.linked?
    assert_equal false, body["meta"]["duplicate"]
    assert_equal "linked", body["data"]["review_status"]
    assert_equal @account.id, body["data"]["account"]["id"]
    assert_equal statement.content_sha256, body["data"]["content_sha256"]
    assert_equal "statement_2024-01.csv", body["data"]["filename"]
  end

  test "uploads an unlinked statement to the inbox" do
    post api_v1_account_statements_url,
         params: { file: statement_upload },
         headers: api_headers(@api_key)

    assert_response :created
    statement = AccountStatement.find(JSON.parse(response.body)["data"]["id"])
    assert_nil statement.account
    assert_not statement.linked?
  end

  test "returns the existing statement for a duplicate upload" do
    existing = AccountStatement.create_from_upload!(family: @family, account: @account, file: statement_upload)

    assert_no_difference "AccountStatement.count" do
      post api_v1_account_statements_url,
           params: { file: statement_upload(filename: "renamed.csv"), account_id: @account.id },
           headers: api_headers(@api_key)
    end

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal existing.id, body["data"]["id"]
    assert_equal true, body["meta"]["duplicate"]
  end

  test "does not reveal a duplicate filed against an account the caller cannot see" do
    private_account = accounts(:other_asset)
    AccountStatement.create_from_upload!(family: @family, account: private_account, file: statement_upload)

    assert_no_difference "AccountStatement.count" do
      post api_v1_account_statements_url,
           params: { file: statement_upload },
           headers: api_headers(@member_api_key)
    end

    assert_response :conflict
    body = JSON.parse(response.body)
    assert_equal "duplicate", body["error"]
    assert_nil body["data"]
    refute_includes response.body, private_account.id
  end

  test "requires a file" do
    assert_no_difference "AccountStatement.count" do
      post api_v1_account_statements_url, params: { account_id: @account.id }, headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "rejects unsupported file types" do
    assert_no_difference "AccountStatement.count" do
      post api_v1_account_statements_url,
           params: { file: uploaded_file(filename: "notes.txt", content_type: "text/plain", content: "hello") },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "rejects an account the caller cannot write to" do
    assert_no_difference "AccountStatement.count" do
      post api_v1_account_statements_url,
           params: { file: statement_upload, account_id: accounts(:credit_card).id },
           headers: api_headers(@member_api_key)
    end

    assert_response :not_found
  end

  test "rejects an account from another family or a malformed id" do
    other_family_account = Account.create!(
      family: families(:empty),
      name: "Other family",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    [ other_family_account.id, "not-a-uuid" ].each do |account_id|
      assert_no_difference "AccountStatement.count" do
        post api_v1_account_statements_url,
             params: { file: statement_upload, account_id: account_id },
             headers: api_headers(@api_key)
      end

      assert_response :not_found
    end
  end

  test "read-only key cannot upload" do
    assert_no_difference "AccountStatement.count" do
      post api_v1_account_statements_url, params: { file: statement_upload }, headers: api_headers(@read_only_api_key)
    end

    assert_response :forbidden
  end

  test "guest cannot use the vault" do
    @guest_api_key = create_api_key(family_guest, "read_write")

    get api_v1_account_statements_url, headers: api_headers(@guest_api_key)
    assert_response :forbidden

    post api_v1_account_statements_url, params: { file: statement_upload }, headers: api_headers(@guest_api_key)
    assert_response :forbidden
  end

  test "guest cannot read a statement on an account shared with them" do
    guest = family_guest
    @account.account_shares.create!(user: guest, permission: "read_only")
    statement = AccountStatement.create_from_upload!(family: @family, account: @account, file: statement_upload)
    assert statement.viewable_by?(guest)
    @guest_api_key = create_api_key(guest, "read")

    get api_v1_account_statement_url(statement), headers: api_headers(@guest_api_key)

    assert_response :forbidden
    refute_includes response.body, statement.id
  end

  test "lists statements the caller can see" do
    linked = AccountStatement.create_from_upload!(family: @family, account: @account, file: statement_upload)
    unlinked = AccountStatement.create_from_upload!(family: @family, account: nil, file: statement_upload(content: "date,amount\n2024-02-01,2\n"))
    private_statement = AccountStatement.create_from_upload!(
      family: @family,
      account: accounts(:other_asset),
      file: statement_upload(content: "date,amount\n2024-03-01,3\n")
    )

    get api_v1_account_statements_url, headers: api_headers(@member_api_key)

    assert_response :success
    body = JSON.parse(response.body)
    ids = body["data"].map { |s| s["id"] }
    assert_includes ids, linked.id
    assert_includes ids, unlinked.id
    refute_includes ids, private_statement.id
    assert_equal ids.size, body["meta"]["total_count"]
  end

  test "filters statements" do
    linked = AccountStatement.create_from_upload!(family: @family, account: @account, file: statement_upload)
    unlinked = AccountStatement.create_from_upload!(family: @family, account: nil, file: statement_upload(content: "date,amount\n2024-02-01,2\n"))
    linked.update!(period_start_on: Date.new(2024, 1, 1), period_end_on: Date.new(2024, 1, 31))
    unlinked.update!(period_start_on: Date.new(2024, 2, 1), period_end_on: Date.new(2024, 2, 29))

    get api_v1_account_statements_url, params: { account_id: @account.id }, headers: api_headers(@read_only_api_key)
    assert_equal [ linked.id ], JSON.parse(response.body)["data"].map { |s| s["id"] }

    get api_v1_account_statements_url, params: { content_sha256: unlinked.content_sha256.upcase }, headers: api_headers(@read_only_api_key)
    assert_equal [ unlinked.id ], JSON.parse(response.body)["data"].map { |s| s["id"] }

    get api_v1_account_statements_url, params: { start_date: "2024-01-15", end_date: "2024-01-20" }, headers: api_headers(@read_only_api_key)
    assert_equal [ linked.id ], JSON.parse(response.body)["data"].map { |s| s["id"] }

    get api_v1_account_statements_url, params: { start_date: "2024-03-01" }, headers: api_headers(@read_only_api_key)
    assert_empty JSON.parse(response.body)["data"]
  end

  test "rejects invalid filters" do
    [ { account_id: "nope" }, { review_status: "approved" }, { start_date: "2024-13-01" } ].each do |filter|
      get api_v1_account_statements_url, params: filter, headers: api_headers(@read_only_api_key)
      assert_response :unprocessable_entity
      assert_equal "validation_failed", JSON.parse(response.body)["error"]
    end
  end

  test "shows a statement" do
    statement = AccountStatement.create_from_upload!(family: @family, account: @account, file: statement_upload)

    get api_v1_account_statement_url(statement), headers: api_headers(@read_only_api_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal statement.id, body["data"]["id"]
    assert_equal @account.name, body["data"]["account"]["name"]
    assert_equal false, body["meta"]["duplicate"]
  end

  test "only shows a suggested account the caller can see" do
    statement = AccountStatement.create_from_upload!(family: @family, account: nil, file: statement_upload)
    statement.update_columns(suggested_account_id: accounts(:other_asset).id, match_confidence: 0.9)

    get api_v1_account_statement_url(statement), headers: api_headers(@api_key)
    assert_equal accounts(:other_asset).id, JSON.parse(response.body)["data"]["suggested_account"]["id"]

    get api_v1_account_statement_url(statement), headers: api_headers(@member_api_key)
    body = JSON.parse(response.body)
    assert_nil body["data"]["suggested_account"]
    assert_nil body["data"]["match_confidence"]
  end

  test "hides statements the caller cannot see" do
    private_statement = AccountStatement.create_from_upload!(family: @family, account: accounts(:other_asset), file: statement_upload)

    get api_v1_account_statement_url(private_statement), headers: api_headers(@member_api_key)
    assert_response :not_found

    get api_v1_account_statement_url("not-a-uuid"), headers: api_headers(@api_key)
    assert_response :not_found

    get api_v1_account_statement_url(SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found
  end

  private

    def create_api_key(user, scope)
      ApiKey.create!(
        user: user,
        name: "Test #{scope} key",
        scopes: [ scope ],
        display_key: "test_#{scope}_#{SecureRandom.hex(8)}",
        source: scope == "read" ? "mobile" : "web"
      )
    end

    def statement_upload(content: "date,amount\n2024-01-01,1\n", filename: "statement_2024-01.csv")
      uploaded_file(filename: filename, content_type: "text/csv", content: content)
    end
end
