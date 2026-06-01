# frozen_string_literal: true

require "test_helper"

class Api::V1::MerchantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other_family_user = users(:empty)

    # Verify cross-family isolation setup is correct
    assert_not_equal @user.family_id, @other_family_user.family_id,
      "Test setup error: @other_family_user must belong to a different family"

    @merchant = @user.family.merchants.first || @user.family.merchants.create!(
      name: "Test Merchant"
    )

    @user.api_keys.active.destroy_all

    @write_api_key = ApiKey.create!(
      user: @user,
      name: "Test Write Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "write_#{SecureRandom.hex(8)}"
    )

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "read_#{SecureRandom.hex(8)}"
    )

    Redis.new.del("api_rate_limit:#{@write_api_key.id}")
    Redis.new.del("api_rate_limit:#{@api_key.id}")
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

  test "index does not return merchants from other families" do
    # Create a merchant in another family
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

  test "should create a merchant" do
    post "/api/v1/merchants",
      params: { merchant: { name: "New Coffee Shop" } },
      headers: { "X-Api-Key" => @write_api_key.plain_key },
      as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "New Coffee Shop", body["name"]
    assert_equal "FamilyMerchant", body["type"]
  end

  test "should reject duplicate merchant name within family" do
    FamilyMerchant.create!(name: "Existing Shop", family: @user.family)

    post "/api/v1/merchants",
      params: { merchant: { name: "Existing Shop" } },
      headers: { "X-Api-Key" => @write_api_key.plain_key },
      as: :json

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "should require read_write scope to create merchant" do
    post "/api/v1/merchants",
      params: { merchant: { name: "Test" } },
      headers: api_headers(@api_key),
      as: :json

    assert_response :forbidden
  end

  test "should require authentication to create merchant" do
    assert_no_difference "FamilyMerchant.count" do
      post "/api/v1/merchants",
        params: { merchant: { name: "Unauth Shop" } },
        as: :json
    end

    assert_response :unauthorized
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
