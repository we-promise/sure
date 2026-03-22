# frozen_string_literal: true

require "test_helper"

class Api::V1::TagsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other_family_user = users(:empty)

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

    @tag = @user.family.tags.create!(name: "Test Tag #{SecureRandom.hex(4)}", color: "#3b82f6")
  end

  # Index action tests
  test "index requires authentication" do
    get api_v1_tags_url

    assert_response :unauthorized
  end

  test "index returns user's family tags successfully" do
    get api_v1_tags_url, headers: read_headers

    assert_response :success

    tags = JSON.parse(response.body)
    assert_kind_of Array, tags
    assert tags.length >= 1

    tag = tags.first
    assert tag.key?("id")
    assert tag.key?("name")
    assert tag.key?("color")
    assert tag.key?("created_at")
    assert tag.key?("updated_at")
  end

  test "index does not return tags from other families" do
    other_tag = @other_family_user.family.tags.create!(name: "Other Tag", color: "#3b82f6")

    get api_v1_tags_url, headers: read_headers

    assert_response :success
    tags = JSON.parse(response.body)
    tag_ids = tags.map { |t| t["id"] }

    assert_includes tag_ids, @tag.id
    assert_not_includes tag_ids, other_tag.id
  end

  # Show action tests
  test "show requires authentication" do
    get api_v1_tag_url(@tag)

    assert_response :unauthorized
  end

  test "show returns tag successfully" do
    get api_v1_tag_url(@tag), headers: read_headers

    assert_response :success

    tag = JSON.parse(response.body)
    assert_equal @tag.id, tag["id"]
    assert_equal @tag.name, tag["name"]
    assert_equal "#3b82f6", tag["color"]
  end

  test "show returns 404 for non-existent tag" do
    get api_v1_tag_url(id: SecureRandom.uuid), headers: read_headers

    assert_response :not_found
  end

  test "show returns 404 for tag from another family" do
    other_tag = @other_family_user.family.tags.create!(name: "Other Tag", color: "#3b82f6")

    get api_v1_tag_url(other_tag), headers: read_headers

    assert_response :not_found
  end

  # Create action tests
  test "create requires authentication" do
    post api_v1_tags_url, params: { tag: { name: "New Tag" } }

    assert_response :unauthorized
  end

  test "create requires read_write scope" do
    post api_v1_tags_url,
         params: { tag: { name: "New Tag", color: "#4da568" } },
         headers: read_headers

    assert_response :forbidden
  end

  test "create tag successfully" do
    tag_name = "New Tag #{SecureRandom.hex(4)}"

    assert_difference -> { @user.family.tags.count }, 1 do
      post api_v1_tags_url,
           params: { tag: { name: tag_name, color: "#4da568" } },
           headers: read_write_headers
    end

    assert_response :created

    tag = JSON.parse(response.body)
    assert_equal tag_name, tag["name"]
    assert_equal "#4da568", tag["color"]
  end

  test "create tag with auto-assigned color" do
    tag_name = "Auto Color Tag #{SecureRandom.hex(4)}"

    post api_v1_tags_url,
         params: { tag: { name: tag_name } },
         headers: read_write_headers

    assert_response :created

    tag = JSON.parse(response.body)
    assert_equal tag_name, tag["name"]
    assert tag["color"].present?
  end

  test "create fails with duplicate name" do
    post api_v1_tags_url,
         params: { tag: { name: @tag.name } },
         headers: read_write_headers

    assert_response :unprocessable_entity
  end

  # Update action tests
  test "update requires authentication" do
    patch api_v1_tag_url(@tag), params: { tag: { name: "Updated" } }

    assert_response :unauthorized
  end

  test "update requires read_write scope" do
    patch api_v1_tag_url(@tag),
          params: { tag: { name: "Updated" } },
          headers: read_headers

    assert_response :forbidden
  end

  test "update tag successfully" do
    new_name = "Updated Tag #{SecureRandom.hex(4)}"

    patch api_v1_tag_url(@tag),
          params: { tag: { name: new_name, color: "#db5a54" } },
          headers: read_write_headers

    assert_response :success

    tag = JSON.parse(response.body)
    assert_equal new_name, tag["name"]
    assert_equal "#db5a54", tag["color"]
  end

  test "update tag partially" do
    original_name = @tag.name

    patch api_v1_tag_url(@tag),
          params: { tag: { color: "#eb5429" } },
          headers: read_write_headers

    assert_response :success

    tag = JSON.parse(response.body)
    assert_equal original_name, tag["name"]
    assert_equal "#eb5429", tag["color"]
  end

  test "update returns 404 for non-existent tag" do
    patch api_v1_tag_url(id: SecureRandom.uuid),
          params: { tag: { name: "Not Found" } },
          headers: read_write_headers

    assert_response :not_found
  end

  test "update returns 404 for tag from another family" do
    other_tag = @other_family_user.family.tags.create!(name: "Other Tag", color: "#3b82f6")

    patch api_v1_tag_url(other_tag),
          params: { tag: { name: "Hacker Update" } },
          headers: read_write_headers

    assert_response :not_found
  end

  # Destroy action tests
  test "destroy requires authentication" do
    delete api_v1_tag_url(@tag)

    assert_response :unauthorized
  end

  test "destroy requires read_write scope" do
    delete api_v1_tag_url(@tag), headers: read_headers

    assert_response :forbidden
  end

  test "destroy tag successfully" do
    tag_to_delete = @user.family.tags.create!(name: "Delete Me #{SecureRandom.hex(4)}", color: "#c44fe9")

    assert_difference -> { @user.family.tags.count }, -1 do
      delete api_v1_tag_url(tag_to_delete), headers: read_write_headers
    end

    assert_response :no_content
  end

  test "destroy returns 404 for non-existent tag" do
    delete api_v1_tag_url(id: SecureRandom.uuid), headers: read_write_headers

    assert_response :not_found
  end

  test "destroy returns 404 for tag from another family" do
    other_tag = @other_family_user.family.tags.create!(name: "Other Tag", color: "#3b82f6")

    assert_no_difference -> { @other_family_user.family.tags.count } do
      delete api_v1_tag_url(other_tag), headers: read_write_headers
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
