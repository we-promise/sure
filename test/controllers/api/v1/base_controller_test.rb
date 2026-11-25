# frozen_string_literal: true

require "test_helper"

class Api::V1::BaseControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read read_write"
    )

    # Clean up any existing API keys for the test user
    @user.api_keys.destroy_all

    # Create a test API key
    @plain_api_key = "base_test_#{SecureRandom.hex(8)}"
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test API Key",
      display_key: @plain_api_key,
      scopes: [ "read_write" ]
    )

    # Clear any existing rate limit data
    Redis.new.del("api_rate_limit:#{@api_key.id}")
  end

  teardown do
    # Clean up Redis data after each test
    Redis.new.del("api_rate_limit:#{@api_key.id}")
  end

  test "uses each authenticated family's timezone in callbacks and actions without leaking it" do
    other_user = users(:empty)
    other_key = ApiKey.create!(user: other_user, name: "Timezone Read", scopes: [ "read" ],
      display_key: "timezone_#{SecureRandom.hex(8)}")
    @user.family.update!(timezone: "America/Los_Angeles")
    other_user.family.update!(timezone: "Asia/Tokyo")

    Time.use_zone("UTC") do
      travel_to Time.utc(2024, 3, 1, 1) do
        [ [ @plain_api_key, "America/Los_Angeles", "2024-02-29" ],
          [ other_key.display_key, "Asia/Tokyo", "2024-03-01" ] ].each do |key, zone, date|
          get "/api/v1/test", headers: { "X-Api-Key" => key }
          assert_response :success
          assert_equal zone, response.parsed_body["time_zone"]
          assert_equal date, response.parsed_body["date"]
          assert_equal date, response.parsed_body["callback_date"]
          assert_equal "UTC", Time.zone.name
        end
      end
    end
  ensure
    Redis.new.del("api_rate_limit:#{other_key.id}") if other_key
  end

  test "should require authentication" do
    # Test that endpoints require OAuth tokens
    get "/api/v1/test"
    assert_response :unauthorized

    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should authenticate with valid access token" do
    # Create a valid access token
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    get "/api/v1/test", params: {}, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    # Should not be unauthorized when token is valid
    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "test_success", response_body["message"]
    assert_equal @user.email, response_body["user"]
  end

  test "should reject revoked access token" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )
    access_token.revoke

    get "/api/v1/test", params: {}, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :unauthorized
    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should reject invalid access token" do
    get "/api/v1/test", params: {}, headers: {
      "Authorization" => "Bearer invalid_token"
    }

    assert_response :unauthorized
    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should authenticate with valid API key" do
    get "/api/v1/test", params: {}, headers: {
      "X-Api-Key" => @plain_api_key
    }

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "test_success", response_body["message"]
    assert_equal @user.email, response_body["user"]
  end

  test "should reject invalid API key" do
    get "/api/v1/test", params: {}, headers: {
      "X-Api-Key" => "invalid_api_key"
    }

    assert_response :unauthorized
    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
    assert_includes response_body["message"], "Access token or API key"
  end

  test "should reject expired API key" do
    @api_key.update!(expires_at: 1.day.ago)

    get "/api/v1/test", params: {}, headers: {
      "X-Api-Key" => @plain_api_key
    }

    assert_response :unauthorized
    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should reject revoked API key" do
    @api_key.revoke!

    get "/api/v1/test", params: {}, headers: {
      "X-Api-Key" => @plain_api_key
    }

    assert_response :unauthorized
    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should update last_used_at when API key is used" do
    original_time = @api_key.last_used_at

    get "/api/v1/test", params: {}, headers: {
      "X-Api-Key" => @plain_api_key
    }

    assert_response :success
    @api_key.reload
    assert_not_equal original_time, @api_key.last_used_at
    assert @api_key.last_used_at > (original_time || Time.at(0))
  end

  test "should prioritize OAuth over API key when both are provided" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    # Capture log output to verify OAuth is used
    logs = capture_log do
      get "/api/v1/test", params: {}, headers: {
        "Authorization" => "Bearer #{access_token.token}",
        "X-Api-Key" => @plain_api_key
      }
    end

    assert_response :success
    assert_includes logs, "OAuth Token"
    assert_not_includes logs, "API Key:"
  end

  test "should provide current_scopes for API key authentication" do
    get "/api/v1/test_scope_required", params: {}, headers: {
      "X-Api-Key" => @plain_api_key
    }

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "scope_authorized", response_body["message"]
    assert_includes response_body["scopes"], "read_write"
  end

  test "should authorize API key with required scope" do
    get "/api/v1/test_scope_required", params: {}, headers: {
      "X-Api-Key" => @plain_api_key
    }

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "scope_authorized", response_body["message"]
    assert_equal "write", response_body["required_scope"]
  end

  test "should reject API key without required scope" do
    # Revoke existing API key and create one with limited scopes
    @api_key.revoke!
    limited_api_key = ApiKey.create!(
      user: @user,
      name: "Limited API Key",
      display_key: "limited_key_#{SecureRandom.hex(8)}",
      scopes: [ "read" ]  # Only read scope
    )

    get "/api/v1/test_scope_required", params: {}, headers: {
      "X-Api-Key" => limited_api_key.display_key
    }

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_body["error"]
    assert_includes response_body["message"], "write"
  end

  test "should authorize API key with multiple required scopes" do
    get "/api/v1/test_multiple_scopes_required", params: {}, headers: {
      "X-Api-Key" => @plain_api_key
    }

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "read_scope_authorized", response_body["message"]
    assert_includes response_body["scopes"], "read_write"
  end

  test "should reject API key missing one of multiple required scopes" do
    # The multiple scopes test now just checks for "read" permission,
    # so we need to create an API key without any scopes at all.
    # First revoke the existing key, then create one with empty scopes array won't work due to validation.
    # Instead, we'll test by trying to access the write endpoint with a read-only key.
    @api_key.revoke!

    read_only_key = ApiKey.create!(
      user: @user,
      name: "Read Only API Key",
      display_key: "read_only_key_#{SecureRandom.hex(8)}",
      scopes: [ "read" ]  # Only read scope, no write
    )

    # Try to access the write-requiring endpoint with read-only key
    get "/api/v1/test_scope_required", params: {}, headers: {
      "X-Api-Key" => read_only_key.display_key
    }

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_body["error"]
  end

  test "should log API access with API key information" do
    logs = capture_log do
      get "/api/v1/test", params: {}, headers: {
        "X-Api-Key" => @plain_api_key
      }
    end

    assert_includes logs, "API Request"
    assert_includes logs, "GET /api/v1/test"
    assert_includes logs, @user.email
  end

  test "should provide current_resource_owner method" do
    # This will be tested through the test controller once implemented
    skip "Will test via test controller implementation"
  end

  test "should handle ActiveRecord::RecordNotFound errors" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    # This will trigger a not found error in the test controller
    get "/api/v1/test_not_found", params: {}, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "record_not_found", response_body["error"]
  end

  test "should log API access" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    # Capture log output
    logs = capture_log do
      get "/api/v1/test", params: {}, headers: {
        "Authorization" => "Bearer #{access_token.token}"
      }
    end

    assert_includes logs, "API Request"
    assert_includes logs, "GET /api/v1/test"
    assert_includes logs, @user.email
  end

  test "should enforce family-based access control" do
    # Create another family user
    other_family = families(:dylan_family)
    other_user = users(:family_member)
    other_user.update!(family: other_family)

    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: other_user.id,
      scopes: "read"
    )

    # Try to access data from a different family
    get "/api/v1/test_family_access", params: {}, headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "forbidden", response_body["error"]
  end

  test "should enforce family-based access control with API key" do
    # Create API key for a user in a different family
    other_family = families(:dylan_family)
    other_user = users(:family_member)
    other_user.update!(family: other_family)
    other_user.api_keys.destroy_all

    other_user_api_key = ApiKey.create!(
      user: other_user,
      name: "Other User API Key",
      display_key: "other_user_key_#{SecureRandom.hex(8)}",
      scopes: [ "read" ]
    )

    # Try to access data from a different family
    get "/api/v1/test_family_access", params: {}, headers: {
      "X-Api-Key" => other_user_api_key.display_key
    }

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "forbidden", response_body["error"]
  end

  test "should include rate limit headers on successful API key requests" do
    get "/api/v1/test", headers: { "X-Api-Key" => @plain_api_key }

    assert_response :success
    assert_not_nil response.headers["X-RateLimit-Limit"]
    assert_not_nil response.headers["X-RateLimit-Remaining"]
    assert_not_nil response.headers["X-RateLimit-Reset"]

    assert_equal "100", response.headers["X-RateLimit-Limit"]
    assert_equal "99", response.headers["X-RateLimit-Remaining"]
  end

  test "should increment rate limit count with each request" do
    # First request
    get "/api/v1/test", headers: { "X-Api-Key" => @plain_api_key }
    assert_response :success
    assert_equal "99", response.headers["X-RateLimit-Remaining"]

    # Second request
    get "/api/v1/test", headers: { "X-Api-Key" => @plain_api_key }
    assert_response :success
    assert_equal "98", response.headers["X-RateLimit-Remaining"]
  end

  test "should return 429 when rate limit exceeded" do
    # Make 100 requests to exhaust the rate limit
    100.times do
      get "/api/v1/test", headers: { "X-Api-Key" => @plain_api_key }
      assert_response :success
    end

    # 101st request should be rate limited
    get "/api/v1/test", headers: { "X-Api-Key" => @plain_api_key }
    assert_response :too_many_requests

    response_body = JSON.parse(response.body)
    assert_equal "rate_limit_exceeded", response_body["error"]
    assert_includes response_body["message"], "Rate limit exceeded"

    # Check response headers
    assert_equal "100", response.headers["X-RateLimit-Limit"]
    assert_equal "0", response.headers["X-RateLimit-Remaining"]
    assert_not_nil response.headers["X-RateLimit-Reset"]
    assert_not_nil response.headers["Retry-After"]
  end

  test "should not apply rate limiting to OAuth requests" do
    # This would need to be implemented based on your OAuth setup
    # For now, just verify that requests without API keys don't trigger rate limiting
    get "/api/v1/test"
    assert_response :unauthorized

    # Should not have rate limit headers for unauthorized requests
    assert_nil response.headers["X-RateLimit-Limit"]
  end

  test "should provide detailed rate limit information in 429 response" do
    # Exhaust the rate limit
    100.times do
      get "/api/v1/test", headers: { "X-Api-Key" => @plain_api_key }
    end

    # Make the rate-limited request
    get "/api/v1/test", headers: { "X-Api-Key" => @plain_api_key }
    assert_response :too_many_requests

    response_body = JSON.parse(response.body)
    assert_equal "rate_limit_exceeded", response_body["error"]
    assert response_body["details"]["limit"] == 100
    assert response_body["details"]["current"] >= 100
    assert response_body["details"]["reset_in_seconds"] > 0
  end

  test "rate limiting should be per API key" do
    # Create a second user for independent API keys
    other_user = users(:family_member)
    other_api_key = ApiKey.create!(
      user: other_user,
      name: "Other Test API Key",
      scopes: [ "read" ],
      display_key: "other_rate_test_#{SecureRandom.hex(8)}"
    )

    begin
      # Make 50 requests with first API key
      50.times do
        get "/api/v1/test", headers: { "X-Api-Key" => @plain_api_key }
        assert_response :success
      end

      # Should still be able to make requests with second API key
      get "/api/v1/test", headers: { "X-Api-Key" => other_api_key.display_key }
      assert_response :success
      assert_equal "99", response.headers["X-RateLimit-Remaining"]
    ensure
      Redis.new.del("api_rate_limit:#{other_api_key.id}")
      other_api_key.destroy
    end
  end

  test "an invalid filter renders a 422 validation error" do
    get "/api/v1/test_filters", params: { flag: "maybe" }, headers: { "X-Api-Key" => @plain_api_key }

    assert_response :unprocessable_entity
    assert_equal(
      { "error" => "validation_failed", "message" => "flag must be true or false", "errors" => [ "flag must be true or false" ] },
      response.parsed_body
    )
  end

  test "a valid filter reaches the action typed" do
    get "/api/v1/test_filters", params: { flag: "FALSE" }, headers: { "X-Api-Key" => @plain_api_key }

    assert_response :success
    assert_equal({ "flag" => false }, response.parsed_body)
  end

  # Every reader: absent is nil; a valid value comes back typed; anything else,
  # including an empty value or an array/hash where a scalar belongs, is a 422.

  test "boolean_filter_param reads true/false/1/0 ignoring case and spaces" do
    { "true" => true, " TRUE " => true, "1" => true, "false" => false, "False" => false, "0" => false }.each do |raw, expected|
      assert_equal expected, read_filter(:boolean_filter_param, raw), raw.inspect
    end
    assert_nil read_filter(:boolean_filter_param, nil)
    assert_invalid_filter "flag must be true or false", :boolean_filter_param, "yes", "", "2", [ "true" ], { "a" => "true" }
  end

  test "boolean_filter_param with required: rejects an absent key" do
    assert_raises_filter("flag must be true or false") { filter_reader({}).send(:boolean_filter_param, :flag, required: true) }
    assert_equal true, filter_reader(flag: "1").send(:boolean_filter_param, :flag, required: true)
  end

  test "date_filter_param reads YYYY-MM-DD only" do
    assert_equal Date.new(2024, 1, 5), read_filter(:date_filter_param, "2024-01-05")
    assert_equal Date.new(2024, 1, 5), read_filter(:date_filter_param, " 2024-01-05 ")
    assert_nil read_filter(:date_filter_param, nil)
    assert_invalid_filter "flag must be an ISO 8601 date", :date_filter_param,
      "", "20240105", "2024-005", "2024-W01-1", "2024-02-30", "Jan 5 2024", "0000-01-05", [ "2024-01-05" ]
  end

  test "time_filter_param reads ISO 8601 timestamps" do
    assert_equal Time.utc(2024, 1, 5, 10, 30), read_filter(:time_filter_param, "2024-01-05T10:30:00Z")
    assert_equal Time.utc(2024, 1, 5, 9, 30), read_filter(:time_filter_param, "2024-01-05T10:30:00+01:00")
    assert_nil read_filter(:time_filter_param, nil)
    assert_invalid_filter "flag must be an ISO 8601 timestamp", :time_filter_param, "", "2024-01-05", "yesterday", [ "2024-01-05T10:30:00Z" ]
  end

  test "decimal_filter_param reads finite numbers" do
    assert_equal BigDecimal("12.5"), read_filter(:decimal_filter_param, "12.5")
    assert_equal BigDecimal("-3"), read_filter(:decimal_filter_param, " -3 ")
    assert_kind_of BigDecimal, read_filter(:decimal_filter_param, "7")
    assert_nil read_filter(:decimal_filter_param, nil)
    assert_invalid_filter "flag must be a number", :decimal_filter_param, "", "abc", "12abc", "Infinity", "NaN", "1\u00002", [ "1" ]
  end

  test "uuid_filter_param reads one UUID" do
    uuid = SecureRandom.uuid
    assert_equal uuid, read_filter(:uuid_filter_param, uuid)
    assert_equal uuid, read_filter(:uuid_filter_param, " #{uuid} ")
    assert_nil read_filter(:uuid_filter_param, nil)
    assert_invalid_filter "flag must be a valid UUID", :uuid_filter_param, "", "123", "#{uuid}x", [ uuid ]
  end

  test "uuid_list_filter_param reads a UUID or a list of them" do
    first, second = SecureRandom.uuid, SecureRandom.uuid
    assert_equal [ first, second ], read_filter(:uuid_list_filter_param, [ first, second ])
    assert_equal [ first ], read_filter(:uuid_list_filter_param, first)
    assert_nil read_filter(:uuid_list_filter_param, nil)
    assert_invalid_filter "flag must be a list of valid UUIDs", :uuid_list_filter_param,
      "", [], [ "" ], [ first, "123" ], "123", { "0" => first }
  end

  test "enum_filter_param reads an exact member of the allowed values" do
    allowed = %w[pending complete]
    assert_equal "pending", filter_reader(flag: "pending").send(:enum_filter_param, :flag, allowed)
    assert_equal "complete", filter_reader(flag: " complete ").send(:enum_filter_param, :flag, allowed)
    assert_nil filter_reader({}).send(:enum_filter_param, :flag, allowed)
    [ "", "Pending", "unknown", [ "pending" ] ].each do |raw|
      assert_raises_filter("flag must be one of: pending, complete") do
        filter_reader(flag: raw).send(:enum_filter_param, :flag, allowed)
      end
    end
  end

  test "string_filter_param reads a stripped string, blank as absent" do
    assert_equal "coffee shop", read_filter(:string_filter_param, "  coffee shop ")
    assert_nil read_filter(:string_filter_param, "   ")
    assert_nil read_filter(:string_filter_param, nil)
    assert_invalid_filter "flag must be a string", :string_filter_param, [ "coffee" ], { "a" => "coffee" }
  end

private

  # A controller holding `flag=raw` (or no flag when raw is nil), as Rails
  # would parse it from a query string.
  def filter_reader(params)
    Api::V1::BaseController.new.tap { |controller| controller.params = ActionController::Parameters.new(params) }
  end

  def read_filter(reader, raw)
    filter_reader(raw.nil? ? {} : { flag: raw }).send(reader, :flag)
  end

  def assert_invalid_filter(message, reader, *raws)
    raws.each do |raw|
      assert_raises_filter(message, raw.inspect) { read_filter(reader, raw) }
    end
  end

  def assert_raises_filter(message, context = nil)
    error = assert_raises(Api::V1::BaseController::InvalidFilterError, *context) { yield }
    assert_equal message, error.message, context
  end

  def capture_log(&block)
    io = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(io)

    yield

    io.string
  ensure
    Rails.logger = original_logger
  end
end
