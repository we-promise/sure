# frozen_string_literal: true

require "test_helper"

class Api::V1::CategoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = families(:dylan_family)

    # Destroy existing active API keys to avoid validation errors
    @user.api_keys.active.destroy_all

    # Create fresh API keys instead of using fixtures to avoid parallel test conflicts (rate limiting)
    @api_key = ApiKey.create!( # pipelock:ignore Credential in URL
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @read_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    # Clear any existing rate limit data
    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_key.id}")

    @category = categories(:food_and_drink)
    @subcategory = categories(:subcategory)
  end

  # INDEX action tests

  test "can list categories" do
    get api_v1_categories_url, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert response_body.key?("categories")
    assert response_body["categories"].is_a?(Array)
    assert response_body["categories"].length > 0

    assert response_body.key?("pagination")
    assert response_body["pagination"].key?("page")
    assert response_body["pagination"].key?("per_page")
    assert response_body["pagination"].key?("total_count")
    assert response_body["pagination"].key?("total_pages")
  end

  # SHOW action tests

  test "can show category" do
    get api_v1_category_url(@category), headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert_equal @category.id, response_body["id"]
    assert_equal @category.name, response_body["name"]
  end

  # CREATE action tests

  test "can create category" do
    category_params = {
      category: {
        name: "New Test Category",
        color: "#4da568",
        lucide_icon: "shopping-cart"
      }
    }

    assert_difference -> { @family.categories.count }, 1 do
      post api_v1_categories_url,
           params: category_params,
           headers: api_headers(@api_key)
    end

    assert_response :created

    response_body = JSON.parse(response.body)
    assert_equal "New Test Category", response_body["name"]
    assert_equal "#4da568", response_body["color"]
    assert_equal "shopping-cart", response_body["icon"]
    assert_nil response_body["parent"]
  end

  test "can create subcategory" do
    category_params = {
      category: {
        name: "Fast Food",
        parent_id: @category.id
      }
    }

    assert_difference -> { @family.categories.count }, 1 do
      post api_v1_categories_url,
           params: category_params,
           headers: api_headers(@api_key)
    end

    assert_response :created

    response_body = JSON.parse(response.body)
    assert_equal "Fast Food", response_body["name"]
    assert response_body["parent"].present?
    assert_equal @category.id, response_body["parent"]["id"]
    assert_equal @category.name, response_body["parent"]["name"]
  end

  test "can create category with auto-assigned color and icon" do
    category_params = {
      category: {
        name: "Groceries Test"
      }
    }

    post api_v1_categories_url,
         params: category_params,
         headers: api_headers(@api_key)

    assert_response :created

    response_body = JSON.parse(response.body)
    assert_equal "Groceries Test", response_body["name"]
    assert response_body["color"].present?
    assert response_body["icon"].present?
  end

  test "returns 422 for invalid category" do
    category_params = {
      category: {
        color: "#4da568"
        # Missing required name
      }
    }

    assert_no_difference -> { @family.categories.count } do
      post api_v1_categories_url,
           params: category_params,
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity

    response_body = JSON.parse(response.body)
    assert_equal "validation_failed", response_body["error"]
    assert response_body["errors"].is_a?(Array)
  end

  test "returns 422 for parent_id from another family" do
    other_family_category = families(:empty).categories.create!(
      name: "Other Family Cat",
      color: "#FF0000",
      lucide_icon: "shapes"
    )

    category_params = {
      category: {
        name: "Sneaky Subcategory",
        parent_id: other_family_category.id
      }
    }

    post api_v1_categories_url,
         params: category_params,
         headers: api_headers(@api_key)

    assert_response :unprocessable_entity

    response_body = JSON.parse(response.body)
    assert_equal "validation_failed", response_body["error"]
  end

  test "create requires authentication" do
    post api_v1_categories_url,
         params: { category: { name: "No Auth" } }

    assert_response :unauthorized
  end

  test "requires read_write scope for create" do
    category_params = {
      category: {
        name: "Should Fail",
        color: "#4da568"
      }
    }

    post api_v1_categories_url,
         params: category_params,
         headers: api_headers(@read_key)

    assert_response :forbidden
  end

  # UPDATE action tests

  test "can update category" do
    new_name = "Updated Category Name"

    patch api_v1_category_url(@category),
          params: { category: { name: new_name } },
          headers: api_headers(@api_key)

    assert_response :success

    response_body = JSON.parse(response.body)
    assert_equal new_name, response_body["name"]
    assert_equal @category.id, response_body["id"]
  end

  test "can partially update category" do
    original_name = @category.name

    patch api_v1_category_url(@category),
          params: { category: { color: "#db5a54" } },
          headers: api_headers(@api_key)

    assert_response :success

    response_body = JSON.parse(response.body)
    assert_equal original_name, response_body["name"]
    assert_equal "#db5a54", response_body["color"]
  end

  test "requires read_write scope for update" do
    patch api_v1_category_url(@category),
          params: { category: { name: "Should Fail" } },
          headers: api_headers(@read_key)

    assert_response :forbidden
  end

  test "returns 404 for updating non-existent category" do
    patch api_v1_category_url(id: SecureRandom.uuid),
          params: { category: { name: "Not Found" } },
          headers: api_headers(@api_key)

    assert_response :not_found
  end

  # DESTROY action tests

  test "can delete category" do
    category_to_delete = @family.categories.create!(
      name: "Delete Me #{SecureRandom.hex(4)}",
      color: "#c44fe9",
      lucide_icon: "shapes"
    )

    assert_difference -> { @family.categories.count }, -1 do
      delete api_v1_category_url(category_to_delete), headers: api_headers(@api_key)
    end

    assert_response :no_content
  end

  test "requires read_write scope for destroy" do
    delete api_v1_category_url(@category), headers: api_headers(@read_key)

    assert_response :forbidden
  end

  test "returns 404 for deleting non-existent category" do
    delete api_v1_category_url(id: SecureRandom.uuid), headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "returns 404 for deleting category from another family" do
    other_family_category = families(:empty).categories.create!(
      name: "Other Family Category",
      color: "#FF0000",
      lucide_icon: "shapes"
    )

    delete api_v1_category_url(other_family_category), headers: api_headers(@api_key)

    assert_response :not_found
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
