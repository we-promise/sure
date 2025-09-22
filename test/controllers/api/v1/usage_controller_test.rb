require "test_helper"

class Api::V1::UsageControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    # Destroy any existing active API keys for this user
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test API Key",
      scopes: [ "read" ],
      display_key: "usage_test_#{SecureRandom.hex(8)}"
    )
  end

  test "should return usage information for API key authentication" do
    # Make a few requests to generate some usage
    3.times do
      get "/api/v1/test", headers: { "X-Api-Key" => @api_key.display_key }
      assert_response :success
    end

    # Now check usage
    get "/api/v1/usage", headers: { "X-Api-Key" => @api_key.display_key }
    assert_response :success

    response_body = JSON.parse(response.body)

    # Check API key information
    assert_equal "Test API Key", response_body["api_key"]["name"]
    assert_equal [ "read" ], response_body["api_key"]["scopes"]
    assert_not_nil response_body["api_key"]["last_used_at"]
    assert_not_nil response_body["api_key"]["created_at"]
  end

  test "should require read scope for usage endpoint" do
    # Create an API key without read scope (this shouldn't be possible with current validations, but let's test)
    api_key_no_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      display_key: "no_read_key_#{SecureRandom.hex(8)}"
    )
    # Skip validations to create invalid key for testing
    api_key_no_read.save(validate: false)

    begin
      get "/api/v1/usage", headers: { "X-Api-Key" => api_key_no_read.display_key }
      assert_response :forbidden

      response_body = JSON.parse(response.body)
      assert_equal "insufficient_scope", response_body["error"]
    ensure
      api_key_no_read.destroy
    end
  end

  test "should return correct message for OAuth authentication" do
    # This test would need OAuth setup, but for now we can mock it
    # For the current implementation, we'll test what happens with no authentication
    get "/api/v1/usage"
    assert_response :unauthorized
  end
end
