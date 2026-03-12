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

    @write_access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )
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

  # ── Create action tests ────────────────────────────────────────────────────

  test "create should require authentication" do
    post "/api/v1/categories",
      params: { category: { name: "Groceries", classification: "expense" } }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end

  test "create should require write scope" do
    post "/api/v1/categories",
      params: { category: { name: "Groceries", classification: "expense" } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :forbidden
  end

  test "create should create a root category with required params" do
    assert_difference "Category.count", 1 do
      post "/api/v1/categories",
        params: { category: { name: "Groceries", classification: "expense" } }.to_json,
        headers: {
          "Authorization" => "Bearer #{@write_access_token.token}",
          "Content-Type" => "application/json"
        }
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "Groceries", body["name"]
    assert_equal "expense", body["classification"]
    assert body["color"].present?, "color should be set to default"
    assert body["icon"].present?, "icon should be set to default"
    assert_nil body["parent"]
  end

  test "create should create a subcategory with valid parent_id" do
    assert_difference "Category.count", 1 do
      post "/api/v1/categories",
        params: {
          category: {
            name: "Coffee",
            classification: "expense",
            parent_id: @category.id
          }
        }.to_json,
        headers: {
          "Authorization" => "Bearer #{@write_access_token.token}",
          "Content-Type" => "application/json"
        }
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "Coffee", body["name"]
    assert_equal @category.id, body["parent"]["id"]
  end

  test "create should accept optional color and icon" do
    post "/api/v1/categories",
      params: {
        category: {
          name: "Transport",
          classification: "expense",
          color: "#ff0000",
          icon: "car"
        }
      }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "#ff0000", body["color"]
    assert_equal "car", body["icon"]
  end

  test "create returns 422 when name is missing" do
    post "/api/v1/categories",
      params: { category: { classification: "expense" } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
  end

  test "create returns 422 when classification is invalid" do
    post "/api/v1/categories",
      params: { category: { name: "Misc", classification: "invalid_value" } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
  end

  test "create returns 422 when parent_id is not found in family" do
    post "/api/v1/categories",
      params: {
        category: {
          name: "Coffee",
          classification: "expense",
          parent_id: "00000000-0000-0000-0000-000000000000"
        }
      }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
    assert_match /Parent category not found/, body["message"]
  end

  test "create returns 422 when parent_id references a subcategory" do
    post "/api/v1/categories",
      params: {
        category: {
          name: "Espresso",
          classification: "expense",
          parent_id: @subcategory.id
        }
      }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match /root category/, body["message"]
  end

  test "create cannot use another family's category as parent" do
    other_family_root = categories(:one) # belongs to :empty family

    post "/api/v1/categories",
      params: {
        category: {
          name: "Coffee",
          classification: "expense",
          parent_id: other_family_root.id
        }
      }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match /Parent category not found/, body["message"]
  end

  # ── Update action tests ────────────────────────────────────────────────────

  test "update should require authentication" do
    patch "/api/v1/categories/#{@category.id}",
      params: { category: { name: "Updated" } }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end

  test "update should require write scope" do
    patch "/api/v1/categories/#{@category.id}",
      params: { category: { name: "Updated" } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :forbidden
  end

  test "update should update category name" do
    patch "/api/v1/categories/#{@category.id}",
      params: { category: { name: "Food & Beverages" } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Food & Beverages", body["name"]
    assert_equal @category.id, body["id"]
  end

  test "update should allow partial update (only name, leaving color unchanged)" do
    original_color = @category.reload.color

    patch "/api/v1/categories/#{@category.id}",
      params: { category: { name: "New Name" } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "New Name", body["name"]
    assert_equal original_color, body["color"], "color should not change when not provided"
  end

  test "update should assign subcategory to a different root parent" do
    # Create a fresh expense root category to use as the new parent
    new_parent = @user.family.categories.create!(
      name: "New Root",
      classification: "expense",
      color: "#aabbcc",
      lucide_icon: "bike"
    )

    patch "/api/v1/categories/#{@subcategory.id}",
      params: { category: { parent_id: new_parent.id } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal new_parent.id, body["parent"]["id"]
  end

  test "update returns 404 for unknown category id" do
    patch "/api/v1/categories/00000000-0000-0000-0000-000000000000",
      params: { category: { name: "X" } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "not_found", body["error"]
  end

  test "update returns 404 for another family's category" do
    other_category = categories(:one) # belongs to :empty family

    patch "/api/v1/categories/#{other_category.id}",
      params: { category: { name: "X" } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :not_found
  end

  test "update returns 422 when classification is set to an invalid value" do
    patch "/api/v1/categories/#{@category.id}",
      params: { category: { classification: "invalid_value" } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
  end

  test "update returns 422 when parent_id references a subcategory" do
    patch "/api/v1/categories/#{@category.id}",
      params: { category: { parent_id: @subcategory.id } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match /root category/, body["message"]
  end

  test "update returns 422 when parent_id is not found in family" do
    patch "/api/v1/categories/#{@category.id}",
      params: { category: { parent_id: "00000000-0000-0000-0000-000000000000" } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match /Parent category not found/, body["message"]
  end

  test "update should assign parent to a root category (root → subcategory)" do
    new_parent = @user.family.categories.create!(
      name: "Big Expense",
      classification: "expense",
      color: "#aabbcc",
      lucide_icon: "bike"
    )
    childless_root = @user.family.categories.create!(
      name: "Childless Expense",
      classification: "expense",
      color: "#123456",
      lucide_icon: "car"
    )

    patch "/api/v1/categories/#{childless_root.id}",
      params: { category: { parent_id: new_parent.id } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal new_parent.id, body["parent"]["id"]
    assert_equal new_parent.name, body["parent"]["name"]
    assert_equal new_parent.id, childless_root.reload.parent_id
  end

  test "update should remove parent from subcategory when parent_id is null" do
    patch "/api/v1/categories/#{@subcategory.id}",
      params: { category: { parent_id: nil } }.to_json,
      headers: {
        "Authorization" => "Bearer #{@write_access_token.token}",
        "Content-Type" => "application/json"
      }

    assert_response :ok
    body = JSON.parse(response.body)
    assert_nil body["parent"]
    assert_equal @subcategory.id, body["id"]
    assert_nil @subcategory.reload.parent_id
  end

  # ── Icons action tests ────────────────────────────────────────────────────

  test "icons returns available icon list without authentication" do
    get "/api/v1/categories/icons"

    assert_response :success
    body = JSON.parse(response.body)

    assert body.key?("icons"), "Response should have 'icons' key"
    assert body["icons"].is_a?(Array), "'icons' should be an array"
    assert body["icons"].length > 0, "Icons list should not be empty"
    assert_includes body["icons"], "bike"
    assert_includes body["icons"], "utensils"
    assert_not_includes body["icons"], "hiking"
  end
end
