# frozen_string_literal: true

require "test_helper"

class Api::V1::MerchantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other_family_user = users(:empty)

    # Verify cross-family isolation setup is correct
    assert_not_equal @user.family_id, @other_family_user.family_id,
      "Test setup error: @other_family_user must belong to a different family"

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test App",
      redirect_uri: "https://example.com/callback",
      scopes: "read read_write"
    )

    @read_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    @read_write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    @merchant = @user.family.merchants.first || @user.family.merchants.create!(
      name: "Test Merchant"
    )
  end

  # Index action tests
  test "index requires authentication" do
    get api_v1_merchants_url

    assert_response :unauthorized
  end

  test "index returns user's family merchants successfully" do
    get api_v1_merchants_url, headers: read_headers

    assert_response :success

    body = JSON.parse(response.body)
    assert body.key?("merchants")
    assert body.key?("pagination")

    merchants = body["merchants"]
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

    get api_v1_merchants_url, headers: read_headers

    assert_response :success
    body = JSON.parse(response.body)
    merchant_ids = body["merchants"].map { |m| m["id"] }

    assert_includes merchant_ids, @merchant.id
    assert_not_includes merchant_ids, other_merchant.id
  end

  # Show action tests
  test "show requires authentication" do
    get api_v1_merchant_url(@merchant)

    assert_response :unauthorized
  end

  test "show returns merchant successfully" do
    get api_v1_merchant_url(@merchant), headers: read_headers

    assert_response :success

    merchant = JSON.parse(response.body)
    assert_equal @merchant.id, merchant["id"]
    assert_equal @merchant.name, merchant["name"]
  end

  test "show returns 404 for non-existent merchant" do
    get api_v1_merchant_url(id: SecureRandom.uuid), headers: read_headers

    assert_response :not_found
  end

  test "show returns 404 for merchant from another family" do
    other_merchant = @other_family_user.family.merchants.create!(name: "Other Merchant")

    get api_v1_merchant_url(other_merchant), headers: read_headers

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
         headers: read_headers

    assert_response :forbidden
  end

  test "create merchant successfully" do
    merchant_name = "New Merchant #{SecureRandom.hex(4)}"

    assert_difference -> { @user.family.merchants.count }, 1 do
      post api_v1_merchants_url,
           params: { merchant: { name: merchant_name } },
           headers: read_write_headers
    end

    assert_response :created

    merchant = JSON.parse(response.body)
    assert_equal merchant_name, merchant["name"]
    assert merchant["color"].present?
  end

  test "create merchant without color assigns default" do
    post api_v1_merchants_url,
         params: { merchant: { name: "No Color Merchant #{SecureRandom.hex(4)}" } },
         headers: read_write_headers

    assert_response :created

    merchant = JSON.parse(response.body)
    assert merchant["color"].present?
  end

  # Update action tests
  test "update requires authentication" do
    patch api_v1_merchant_url(@merchant), params: { merchant: { name: "Updated" } }

    assert_response :unauthorized
  end

  test "update requires read_write scope" do
    patch api_v1_merchant_url(@merchant),
          params: { merchant: { name: "Updated" } },
          headers: read_headers

    assert_response :forbidden
  end

  test "update merchant successfully" do
    new_name = "Updated Merchant #{SecureRandom.hex(4)}"

    patch api_v1_merchant_url(@merchant),
          params: { merchant: { name: new_name } },
          headers: read_write_headers

    assert_response :success

    merchant = JSON.parse(response.body)
    assert_equal new_name, merchant["name"]
  end

  test "update returns 404 for non-existent merchant" do
    patch api_v1_merchant_url(id: SecureRandom.uuid),
          params: { merchant: { name: "Not Found" } },
          headers: read_write_headers

    assert_response :not_found
  end

  test "update returns 404 for merchant from another family" do
    other_merchant = @other_family_user.family.merchants.create!(name: "Other Merchant")

    patch api_v1_merchant_url(other_merchant),
          params: { merchant: { name: "Hacker Update" } },
          headers: read_write_headers

    assert_response :not_found
  end

  # Destroy action tests
  test "destroy requires authentication" do
    delete api_v1_merchant_url(@merchant)

    assert_response :unauthorized
  end

  test "destroy requires read_write scope" do
    delete api_v1_merchant_url(@merchant), headers: read_headers

    assert_response :forbidden
  end

  test "destroy merchant successfully" do
    merchant_to_delete = @user.family.merchants.create!(name: "Delete Me #{SecureRandom.hex(4)}")

    assert_difference -> { @user.family.merchants.count }, -1 do
      delete api_v1_merchant_url(merchant_to_delete), headers: read_write_headers
    end

    assert_response :success
  end

  test "destroy returns 404 for non-existent merchant" do
    delete api_v1_merchant_url(id: SecureRandom.uuid), headers: read_write_headers

    assert_response :not_found
  end

  test "destroy returns 404 for merchant from another family" do
    other_merchant = @other_family_user.family.merchants.create!(name: "Other Merchant")

    assert_no_difference -> { @other_family_user.family.merchants.count } do
      delete api_v1_merchant_url(other_merchant), headers: read_write_headers
    end

    assert_response :not_found
  end

  private

    def read_headers
      { "Authorization" => "Bearer #{@read_token.token}" }
    end

    def read_write_headers
      { "Authorization" => "Bearer #{@read_write_token.token}" }
    end
end
