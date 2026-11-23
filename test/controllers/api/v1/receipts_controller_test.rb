# frozen_string_literal: true

require "test_helper"

class Api::V1::ReceiptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @family = @admin.family
    @account = accounts(:depository)
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => true))

    @admin.api_keys.active.destroy_all
    @api_key = create_api_key(@admin, "read_write")
    @read_only_api_key = create_api_key(@admin, "read")
    use_ai_routes
    Provider::Registry.stubs(:preferred_llm_provider).returns(stub(supports_receipt_extraction?: true))
  end

  test "403 when receipt scanning is unavailable" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(stub(supports_receipt_extraction?: false))

    assert_no_difference "ReceiptScan.count" do
      post api_v1_receipts_url,
           params: { account_id: @account.id, files: [ receipt_upload ] },
           headers: api_headers(@api_key)
    end

    assert_response :forbidden
    assert_equal "ai_unavailable", JSON.parse(response.body)["error"]
  end

  test "403 when the user hasn't turned on preview features" do
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => false))

    assert_no_difference "ReceiptScan.count" do
      post api_v1_receipts_url,
           params: { account_id: @account.id, files: [ receipt_upload ] },
           headers: api_headers(@api_key)
    end

    assert_response :forbidden
    assert_equal "preview_required", JSON.parse(response.body)["error"]
  end

  teardown do
    redis = Redis.new
    [ @api_key, @read_only_api_key ].each { |key| redis.del("api_rate_limit:#{key.id}") }
    redis.close
  end

  test "requires authentication" do
    post api_v1_receipts_url, params: { account_id: @account.id, files: [ receipt_upload ] }
    assert_response :unauthorized
  end

  test "creates scan 202" do
    assert_difference [ "ReceiptScan.count", "Entry.count" ], 1 do
      post api_v1_receipts_url,
           params: { account_id: @account.id, files: [ receipt_upload ] },
           headers: api_headers(@api_key)
    end

    assert_response :accepted
    body = JSON.parse(response.body)
    scan = ReceiptScan.find(body["id"])
    assert_equal "processing", body["status"]
    assert_equal @account.id, body["account_id"]
    assert_equal scan.linked_transaction.id, body["transaction_id"]
    assert_equal [], body["review_reasons"]
  end

  test "404 for other family account" do
    other_account = families(:empty).accounts.create!(
      name: "Elsewhere", balance: 0, currency: "USD", accountable: Depository.new, owner: users(:empty)
    )

    assert_no_difference "ReceiptScan.count" do
      post api_v1_receipts_url,
           params: { account_id: other_account.id, files: [ receipt_upload ] },
           headers: api_headers(@api_key)
    end

    assert_response :not_found
  end

  test "422 for 6 files" do
    post api_v1_receipts_url,
         params: { account_id: @account.id, files: Array.new(6) { receipt_upload } },
         headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "403 read-only key on create" do
    post api_v1_receipts_url,
         params: { account_id: @account.id, files: [ receipt_upload ] },
         headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "show returns status" do
    scan = receipt_scans(:processing)
    scan.flag!(:items_total_mismatch, total: "50.0")

    get api_v1_receipt_url(scan), headers: api_headers(@read_only_api_key)

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "needs_review", body["status"]
    assert_equal [ { "reason" => "items_total_mismatch", "total" => "50.0" } ], body["review_reasons"]
  end

  test "show 404 other family" do
    scan = ReceiptScan.create!(family: families(:empty), user: users(:empty),
                               account: families(:empty).accounts.create!(name: "X", balance: 0, currency: "USD",
                                                                          accountable: Depository.new, owner: users(:empty)))

    get api_v1_receipt_url(scan), headers: api_headers(@api_key)

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

    def receipt_upload
      Rack::Test::UploadedFile.new(file_fixture("receipts/rotated.jpg"), "image/jpeg")
    end
end
