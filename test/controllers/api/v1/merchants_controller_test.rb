# frozen_string_literal: true

require "test_helper"

class Api::V1::MerchantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other_family_user = users(:family_member)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test App",
      redirect_uri: "https://example.com/callback",
      scopes: "read"
    )

    @access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    @other_family_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @other_family_user.id,
      scopes: "read"
    )

    @merchant = @user.family.merchants.create!(
      name: "Test Merchant",
      color: "#3b82f6"
    )
  end

  # Index action tests
  test "index requires authentication" do
    get api_v1_merchants_url

    assert_response :unauthorized
  end

  test "index returns user's family merchants successfully" do
    get api_v1_merchants_url, headers: auth_headers

    assert_response :success

    merchants = JSON.parse(response.body)
    assert_kind_of Array, merchants
    assert merchants.length >= 1

    merchant = merchants.first
    assert merchant.key?("id")
    assert merchant.key?("name")
    assert merchant.key?("color")
    assert merchant.key?("created_at")
    assert merchant.key?("updated_at")
  end

  test "index does not return other family's merchants" do
    other_merchant = @other_family_user.family.merchants.create!(
      name: "Other Family Merchant",
      color: "#ef4444"
    )

    get api_v1_merchants_url, headers: auth_headers

    assert_response :success

    merchants = JSON.parse(response.body)
    merchant_ids = merchants.map { |m| m["id"] }

    assert_not_includes merchant_ids, other_merchant.id
  end

  # Show action tests
  test "show requires authentication" do
    get api_v1_merchant_url(@merchant)

    assert_response :unauthorized
  end

  test "show returns merchant successfully" do
    get api_v1_merchant_url(@merchant), headers: auth_headers

    assert_response :success

    merchant = JSON.parse(response.body)
    assert_equal @merchant.id, merchant["id"]
    assert_equal "Test Merchant", merchant["name"]
    assert_equal "#3b82f6", merchant["color"]
  end

  test "show returns 404 for non-existent merchant" do
    get api_v1_merchant_url(id: "00000000-0000-0000-0000-000000000000"), headers: auth_headers

    assert_response :not_found
  end

  test "show returns 404 for other family's merchant" do
    other_merchant = @other_family_user.family.merchants.create!(
      name: "Other Family Merchant",
      color: "#ef4444"
    )

    get api_v1_merchant_url(other_merchant), headers: auth_headers

    assert_response :not_found
  end

  private

  def auth_headers
    { "Authorization" => "Bearer #{@access_token.token}" }
  end
end
