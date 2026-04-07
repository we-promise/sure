# frozen_string_literal: true

require "test_helper"

class Api::V1::MerchantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @other_family_user = users(:empty)

    # Verify cross-family isolation setup is correct
    assert_not_equal @user.family_id, @other_family_user.family_id,
      "Test setup error: @other_family_user must belong to a different family"

    # Destroy existing active API keys to avoid validation errors
    @user.api_keys.active.destroy_all

    # Create fresh API keys instead of using fixtures to avoid parallel test conflicts (rate limiting)
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

    # Clear any existing rate limit data
    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")

    @merchant = @family.merchants.first || @family.merchants.create!(
      name: "Test Merchant"
    )
  end

  # Index action tests
  test "index requires authentication" do
    get api_v1_merchants_url

    assert_response :unauthorized
  end

  test "index returns user's family merchants successfully" do
    get api_v1_merchants_url, headers: api_headers(@api_key)

    assert_response :success

    merchants = JSON.parse(response.body)
    assert_kind_of Array, merchants
    assert_not_empty merchants

    merchant = merchants.first
    assert merchant.key?("id")
    assert merchant.key?("name")
    assert merchant.key?("created_at")
    assert merchant.key?("updated_at")
  end

  test "index works with read-only API key" do
    get api_v1_merchants_url, headers: api_headers(@read_only_api_key)

    assert_response :success
  end

  test "index does not return merchants from other families" do
    other_merchant = @other_family_user.family.merchants.create!(name: "Other Merchant")

    get api_v1_merchants_url, headers: api_headers(@api_key)

    assert_response :success
    merchants = JSON.parse(response.body)
    merchant_ids = merchants.map { |m| m["id"] }

    assert_includes merchant_ids, @merchant.id
    assert_not_includes merchant_ids, other_merchant.id
  end

  # Show action tests
  test "show requires authentication" do
    get api_v1_merchant_url(@merchant)

    assert_response :unauthorized
  end

  test "show returns merchant successfully" do
    get api_v1_merchant_url(@merchant), headers: api_headers(@api_key)

    assert_response :success

    merchant = JSON.parse(response.body)
    assert_equal @merchant.id, merchant["id"]
    assert_equal @merchant.name, merchant["name"]
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

  # Create action tests
  test "create requires authentication" do
    post api_v1_merchants_url, params: { merchant: { name: "New Merchant" } }

    assert_response :unauthorized
  end

  test "create requires read_write scope" do
    post api_v1_merchants_url,
         params: { merchant: { name: "New Merchant" } },
         headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "create merchant successfully" do
    merchant_name = "New Merchant #{SecureRandom.hex(4)}"

    assert_difference -> { @family.merchants.count }, 1 do
      post api_v1_merchants_url,
           params: { merchant: { name: merchant_name, color: "#123456" } },
           headers: api_headers(@api_key)
    end

    assert_response :created

    merchant = JSON.parse(response.body)
    assert_equal merchant_name, merchant["name"]
    assert_equal "#123456", merchant["color"]
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
    assert_includes FamilyMerchant::COLORS, merchant["color"]
  end

  test "create merchant with website_url" do
    merchant_name = "Website Merchant #{SecureRandom.hex(4)}"

    post api_v1_merchants_url,
         params: { merchant: { name: merchant_name, website_url: "https://example.com" } },
         headers: api_headers(@api_key)

    assert_response :created

    merchant = JSON.parse(response.body)
    assert_equal merchant_name, merchant["name"]
    assert_equal "https://example.com", merchant["website_url"]
  end

  test "create fails with duplicate name in same family" do
    post api_v1_merchants_url,
         params: { merchant: { name: @merchant.name } },
         headers: api_headers(@api_key)

    assert_response :unprocessable_entity
  end

  test "create fails without name" do
    assert_no_difference -> { @family.merchants.count } do
      post api_v1_merchants_url,
           params: { merchant: { color: "#123456" } },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
  end

  # Update action tests
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
          params: { merchant: { name: new_name, color: "#abcdef" } },
          headers: api_headers(@api_key)

    assert_response :success

    merchant = JSON.parse(response.body)
    assert_equal new_name, merchant["name"]
    assert_equal "#abcdef", merchant["color"]
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
          params: { merchant: { name: "Hijack" } },
          headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "update returns 422 for invalid params" do
    patch api_v1_merchant_url(@merchant),
          params: { merchant: { name: "" } },
          headers: api_headers(@api_key)

    assert_response :unprocessable_entity
  end

  # Destroy action tests
  test "destroy requires authentication" do
    delete api_v1_merchant_url(@merchant)

    assert_response :unauthorized
  end

  test "destroy requires read_write scope" do
    delete api_v1_merchant_url(@merchant), headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "destroy merchant successfully" do
    merchant_to_delete = @family.merchants.create!(name: "Delete Me #{SecureRandom.hex(4)}")

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

    delete api_v1_merchant_url(other_merchant), headers: api_headers(@api_key)

    assert_response :not_found
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
