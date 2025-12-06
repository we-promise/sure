# frozen_string_literal: true

require "test_helper"

class Api::V1::SyncControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    # Destroy existing active API keys to avoid validation errors
    @user.api_keys.active.destroy_all

    # Create fresh API keys
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
  end

  test "should trigger sync with valid write API key" do
    assert_enqueued_with(job: SyncJob) do
      post api_v1_sync_url, headers: api_headers(@api_key)
    end

    assert_response :accepted

    response_data = JSON.parse(response.body)
    assert response_data.key?("id")
    assert response_data.key?("status")
    assert_equal "Family", response_data["syncable_type"]
    assert_equal @family.id, response_data["syncable_id"]
    assert response_data.key?("message")
    assert_includes response_data["message"], "rules"
  end

  test "should reject sync with read-only API key" do
    post api_v1_sync_url, headers: api_headers(@read_only_api_key)
    assert_response :forbidden

    response_data = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_data["error"]
  end

  test "should reject sync without API key" do
    post api_v1_sync_url
    assert_response :unauthorized

    response_data = JSON.parse(response.body)
    assert response_data.key?("error")
  end

  test "should return proper sync details in response" do
    post api_v1_sync_url, headers: api_headers(@api_key)
    assert_response :accepted

    response_data = JSON.parse(response.body)

    # Check all expected fields are present
    assert response_data.key?("id")
    assert response_data.key?("status")
    assert response_data.key?("syncable_type")
    assert response_data.key?("syncable_id")
    assert response_data.key?("syncing_at")
    assert response_data.key?("completed_at")
    assert response_data.key?("window_start_date")
    assert response_data.key?("window_end_date")
    assert response_data.key?("message")
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
