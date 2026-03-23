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

    @api_key = api_keys(:active_key)
    @read_only_api_key = api_keys(:read_only_key)

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
           params: { merchant: { name: merchant_name, color: "#e99537" } },
           headers: api_headers(@api_key)
    end

    assert_response :created

    merchant = JSON.parse(response.body)
    assert_equal merchant_name, merchant["name"]
    assert merchant["color"].present?
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
           params: { merchant: { color: "#e99537" } },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
