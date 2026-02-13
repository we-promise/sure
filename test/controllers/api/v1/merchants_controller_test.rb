# frozen_string_literal: true

require "test_helper"

class Api::V1::MerchantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @other_family_user = users(:empty)

    assert_not_equal @user.family_id, @other_family_user.family_id,
      "Test setup error: @other_family_user must belong to a different family"

    # Destroy existing active API keys to avoid validation errors
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
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

    @merchant = @family.merchants.first || @family.merchants.create!(name: "Test Merchant")
  end

  # ── INDEX ─────────────────────────────────────────────────────────

  test "index requires authentication" do
    get api_v1_merchants_url
    assert_response :unauthorized
  end

  test "index returns merchants with API key" do
    get api_v1_merchants_url, headers: api_headers(@api_key)
    assert_response :success

    merchants = JSON.parse(response.body)
    assert_kind_of Array, merchants
    assert_not_empty merchants

    merchant = merchants.first
    assert merchant.key?("id")
    assert merchant.key?("name")
    assert merchant.key?("type")
    assert merchant.key?("color")
    assert merchant.key?("created_at")
    assert merchant.key?("updated_at")
  end

  test "index returns merchants with read-only API key" do
    get api_v1_merchants_url, headers: api_headers(@read_only_api_key)
    assert_response :success
  end

  test "index does not return merchants from other families" do
    other_merchant = @other_family_user.family.merchants.create!(name: "Other Family Merchant")

    get api_v1_merchants_url, headers: api_headers(@api_key)
    assert_response :success

    merchants = JSON.parse(response.body)
    merchant_ids = merchants.map { |m| m["id"] }

    assert_includes merchant_ids, @merchant.id
    assert_not_includes merchant_ids, other_merchant.id
  end

  # ── SHOW ──────────────────────────────────────────────────────────

  test "show requires authentication" do
    get api_v1_merchant_url(@merchant)
    assert_response :unauthorized
  end

  test "show returns merchant with API key" do
    get api_v1_merchant_url(@merchant), headers: api_headers(@api_key)
    assert_response :success

    merchant = JSON.parse(response.body)
    assert_equal @merchant.id, merchant["id"]
    assert_equal @merchant.name, merchant["name"]
    assert_equal @merchant.type, merchant["type"]
  end

  test "show returns 404 for non-existent merchant" do
    get api_v1_merchant_url(id: SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "show returns 404 for merchant from another family" do
    other_merchant = @other_family_user.family.merchants.create!(name: "Other Merchant")

    get api_v1_merchant_url(other_merchant), headers: api_headers(@api_key)
    assert_response :not_found
  end

  # ── CREATE ────────────────────────────────────────────────────────

  test "create requires authentication" do
    post api_v1_merchants_url, params: { merchant: { name: "New Merchant" } }
    assert_response :unauthorized
  end

  test "create requires read_write scope" do
    post api_v1_merchants_url,
         params: { merchant: { name: "New Merchant", color: "#4da568" } },
         headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "create merchant successfully" do
    merchant_name = "New Merchant #{SecureRandom.hex(4)}"

    assert_difference -> { @family.merchants.count }, 1 do
      post api_v1_merchants_url,
           params: { merchant: { name: merchant_name, color: "#4da568" } },
           headers: api_headers(@api_key)
    end

    assert_response :created

    merchant = JSON.parse(response.body)
    assert_equal merchant_name, merchant["name"]
    assert_equal "#4da568", merchant["color"]
    assert_equal "FamilyMerchant", merchant["type"]
  end

  test "create merchant with auto-assigned color" do
    merchant_name = "Auto Color Merchant #{SecureRandom.hex(4)}"

    post api_v1_merchants_url,
         params: { merchant: { name: merchant_name } },
         headers: api_headers(@api_key)

    assert_response :created

    merchant = JSON.parse(response.body)
    assert_equal merchant_name, merchant["name"]
    assert merchant["color"].present?
  end

  test "create fails with duplicate name in same family" do
    post api_v1_merchants_url,
         params: { merchant: { name: @merchant.name } },
         headers: api_headers(@api_key)

    assert_response :unprocessable_entity
  end

  # ── UPDATE ────────────────────────────────────────────────────────

  test "update requires authentication" do
    patch api_v1_merchant_url(@merchant), params: { merchant: { name: "Updated" } }
    assert_response :unauthorized
  end

  test "update requires read_write scope" do
    patch api_v1_merchant_url(@merchant),
          params: { merchant: { name: "Updated" } },
          headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "update merchant successfully" do
    new_name = "Updated Merchant #{SecureRandom.hex(4)}"

    patch api_v1_merchant_url(@merchant),
          params: { merchant: { name: new_name, color: "#db5a54" } },
          headers: api_headers(@api_key)

    assert_response :success

    merchant = JSON.parse(response.body)
    assert_equal new_name, merchant["name"]
    assert_equal "#db5a54", merchant["color"]
  end

  test "update merchant partially" do
    original_name = @merchant.name

    patch api_v1_merchant_url(@merchant),
          params: { merchant: { color: "#eb5429" } },
          headers: api_headers(@api_key)

    assert_response :success

    merchant = JSON.parse(response.body)
    assert_equal original_name, merchant["name"]
    assert_equal "#eb5429", merchant["color"]
  end

  test "update returns 404 for non-existent merchant" do
    patch api_v1_merchant_url(id: SecureRandom.uuid),
          params: { merchant: { name: "Not Found" } },
          headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "update returns 404 for merchant from another family" do
    other_merchant = @other_family_user.family.merchants.create!(name: "Other Merchant")

    patch api_v1_merchant_url(other_merchant),
          params: { merchant: { name: "Hacker Update" } },
          headers: api_headers(@api_key)
    assert_response :not_found
  end

  # ── DESTROY ───────────────────────────────────────────────────────

  test "destroy requires authentication" do
    delete api_v1_merchant_url(@merchant)
    assert_response :unauthorized
  end

  test "destroy requires read_write scope" do
    delete api_v1_merchant_url(@merchant), headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "destroy merchant successfully" do
    merchant_to_delete = @family.merchants.create!(name: "Delete Me #{SecureRandom.hex(4)}", color: "#c44fe9")

    assert_difference -> { @family.merchants.count }, -1 do
      delete api_v1_merchant_url(merchant_to_delete), headers: api_headers(@api_key)
    end

    assert_response :no_content
  end

  test "destroy returns 404 for non-existent merchant" do
    delete api_v1_merchant_url(id: SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "destroy returns 404 for merchant from another family" do
    other_merchant = @other_family_user.family.merchants.create!(name: "Other Merchant")

    assert_no_difference -> { @other_family_user.family.merchants.count } do
      delete api_v1_merchant_url(other_merchant), headers: api_headers(@api_key)
    end

    assert_response :not_found
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
