# frozen_string_literal: true

require "test_helper"

class Api::V1::CategoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin) # dylan_family user
    @other_family_user = users(:family_member)
    @other_family_user.update!(family: families(:empty))

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read read_write"
    )

    @access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    @category = categories(:food_and_drink)
    @subcategory = categories(:subcategory)
  end

  # Index action tests

  test "should require authentication" do
    get "/api/v1/categories"
    assert_response :unauthorized

    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should return user's family categories successfully" do
    get "/api/v1/categories", params: {}, headers: {
      "Authorization" => "Bearer #{@access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    assert response_body.key?("categories")
    assert response_body["categories"].is_a?(Array)

    assert response_body.key?("pagination")
    assert response_body["pagination"].key?("page")
    assert response_body["pagination"].key?("per_page")
    assert response_body["pagination"].key?("total_count")
    assert response_body["pagination"].key?("total_pages")
  end

  test "should not return other family's categories" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @other_family_user.id,
      scopes: "read"
    )

    get "/api/v1/categories", params: {}, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should not include dylan_family's categories
    category_names = response_body["categories"].map { |c| c["name"] }
    assert_not_includes category_names, @category.name
  end

  test "should return proper category data structure" do
    get "/api/v1/categories", params: {}, headers: {
      "Authorization" => "Bearer #{@access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    assert response_body["categories"].length > 0

    category = response_body["categories"].find { |c| c["name"] == @category.name }
    assert category.present?, "Should find the food_and_drink category"

    required_fields = %w[id name classification color icon subcategories_count created_at updated_at]
    required_fields.each do |field|
      assert category.key?(field), "Category should have #{field} field"
    end

    assert category["id"].is_a?(String), "ID should be string (UUID)"
    assert category["name"].is_a?(String), "Name should be string"
    assert category["color"].is_a?(String), "Color should be string"
    assert category["icon"].is_a?(String), "Icon should be string"
  end

  test "should include parent information for subcategories" do
    get "/api/v1/categories", params: {}, headers: {
      "Authorization" => "Bearer #{@access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    subcategory = response_body["categories"].find { |c| c["name"] == @subcategory.name }
    assert subcategory.present?, "Should find the subcategory"

    assert subcategory["parent"].present?, "Subcategory should have parent"
    assert_equal @category.id, subcategory["parent"]["id"]
    assert_equal @category.name, subcategory["parent"]["name"]
  end

  test "should handle pagination parameters" do
    get "/api/v1/categories", params: { page: 1, per_page: 2 }, headers: {
      "Authorization" => "Bearer #{@access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    assert response_body["categories"].length <= 2
    assert_equal 1, response_body["pagination"]["page"]
    assert_equal 2, response_body["pagination"]["per_page"]
  end

  test "should filter by classification" do
    get "/api/v1/categories", params: { classification: "expense" }, headers: {
      "Authorization" => "Bearer #{@access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    response_body["categories"].each do |category|
      assert_equal "expense", category["classification"]
    end
  end

  test "should filter for roots only" do
    get "/api/v1/categories", params: { roots_only: true }, headers: {
      "Authorization" => "Bearer #{@access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    response_body["categories"].each do |category|
      assert_nil category["parent"], "Root categories should not have a parent"
    end
  end

  test "should sort categories alphabetically" do
    get "/api/v1/categories", params: {}, headers: {
      "Authorization" => "Bearer #{@access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    category_names = response_body["categories"].map { |c| c["name"] }
    assert_equal category_names.sort, category_names
  end

  # Show action tests

  test "should return a single category" do
    get "/api/v1/categories/#{@category.id}", params: {}, headers: {
      "Authorization" => "Bearer #{@access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    assert_equal @category.id, response_body["id"]
    assert_equal @category.name, response_body["name"]
    assert_equal @category.classification, response_body["classification"]
    assert_equal @category.color, response_body["color"]
    assert_equal @category.lucide_icon, response_body["icon"]
  end

  test "should return 404 for non-existent category" do
    get "/api/v1/categories/00000000-0000-0000-0000-000000000000", params: {}, headers: {
      "Authorization" => "Bearer #{@access_token.token}"
    }

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
  end

  test "should not return category from another family" do
    other_family_category = categories(:one) # belongs to :empty family

    get "/api/v1/categories/#{other_family_category.id}", params: {}, headers: {
      "Authorization" => "Bearer #{@access_token.token}"
    }

    assert_response :not_found
  end
end
