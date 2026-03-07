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

  # Create action tests

  test "create requires authentication" do
    post "/api/v1/categories", params: { category: { name: "New Category" } }

    assert_response :unauthorized
  end

  test "create requires read_write scope" do
    post "/api/v1/categories",
         params: { category: { name: "New Category", classification: "expense" } },
         headers: { "Authorization" => "Bearer #{@access_token.token}" }

    assert_response :forbidden
  end

  test "create category successfully" do
    read_write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    category_name = "New Category #{SecureRandom.hex(4)}"

    assert_difference -> { @user.family.categories.count }, 1 do
      post "/api/v1/categories",
           params: { category: { name: category_name, classification: "expense", color: "#ff0000" } },
           headers: { "Authorization" => "Bearer #{read_write_token.token}" }
    end

    assert_response :created

    category = JSON.parse(response.body)
    assert_equal category_name, category["name"]
    assert_equal "expense", category["classification"]
    assert_equal "#ff0000", category["color"]
  end

  test "create subcategory with parent_id" do
    read_write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    subcategory_name = "Sub Category #{SecureRandom.hex(4)}"

    post "/api/v1/categories",
         params: { category: { name: subcategory_name, classification: "expense", parent_id: @category.id } },
         headers: { "Authorization" => "Bearer #{read_write_token.token}" }

    assert_response :created

    category = JSON.parse(response.body)
    assert_equal subcategory_name, category["name"]
    assert_equal @category.id, category["parent"]["id"]
  end

  # Update action tests

  test "update requires authentication" do
    patch "/api/v1/categories/#{@category.id}", params: { category: { name: "Updated" } }

    assert_response :unauthorized
  end

  test "update requires read_write scope" do
    patch "/api/v1/categories/#{@category.id}",
          params: { category: { name: "Updated" } },
          headers: { "Authorization" => "Bearer #{@access_token.token}" }

    assert_response :forbidden
  end

  test "update category successfully" do
    read_write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    new_name = "Updated Category #{SecureRandom.hex(4)}"

    patch "/api/v1/categories/#{@category.id}",
          params: { category: { name: new_name, color: "#00ff00" } },
          headers: { "Authorization" => "Bearer #{read_write_token.token}" }

    assert_response :success

    category = JSON.parse(response.body)
    assert_equal new_name, category["name"]
    assert_equal "#00ff00", category["color"]
  end

  test "update returns 404 for non-existent category" do
    read_write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    patch "/api/v1/categories/#{SecureRandom.uuid}",
          params: { category: { name: "Not Found" } },
          headers: { "Authorization" => "Bearer #{read_write_token.token}" }

    assert_response :not_found
  end

  test "update returns 404 for category from another family" do
    read_write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    other_family_category = categories(:one)

    patch "/api/v1/categories/#{other_family_category.id}",
          params: { category: { name: "Hacker Update" } },
          headers: { "Authorization" => "Bearer #{read_write_token.token}" }

    assert_response :not_found
  end

  # Destroy action tests

  test "destroy requires authentication" do
    delete "/api/v1/categories/#{@category.id}"

    assert_response :unauthorized
  end

  test "destroy requires read_write scope" do
    delete "/api/v1/categories/#{@category.id}",
           headers: { "Authorization" => "Bearer #{@access_token.token}" }

    assert_response :forbidden
  end

  test "destroy category successfully" do
    read_write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    category_to_delete = @user.family.categories.create!(
      name: "Delete Me #{SecureRandom.hex(4)}",
      classification: "expense",
      color: "#ff0000"
    )

    assert_difference -> { @user.family.categories.count }, -1 do
      delete "/api/v1/categories/#{category_to_delete.id}",
             headers: { "Authorization" => "Bearer #{read_write_token.token}" }
    end

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "Category deleted successfully", response_body["message"]
  end

  test "destroy returns 404 for non-existent category" do
    read_write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    delete "/api/v1/categories/#{SecureRandom.uuid}",
           headers: { "Authorization" => "Bearer #{read_write_token.token}" }

    assert_response :not_found
  end

  test "destroy returns 404 for category from another family" do
    read_write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    other_family_category = categories(:one)

    assert_no_difference -> { Category.count } do
      delete "/api/v1/categories/#{other_family_category.id}",
             headers: { "Authorization" => "Bearer #{read_write_token.token}" }
    end

    assert_response :not_found
  end
end
