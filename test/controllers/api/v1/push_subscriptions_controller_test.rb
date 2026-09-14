require "test_helper"

class Api::V1::PushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    key = ApiKey.generate_secure_key
    @api_key = ApiKey.create!(
      user: @user,
      name: "Native push test",
      key: key,
      scopes: [ "read_write" ],
      source: "mobile"
    )
    @headers = api_headers(@api_key)
    @token = "ab" * 32
  end

  test "registers and refreshes an APNs token" do
    assert_difference "PushSubscription.count", 1 do
      post api_v1_push_subscriptions_url,
           params: { token: @token, environment: "sandbox", platform: "ios" },
           headers: @headers,
           as: :json
    end

    assert_response :created
    subscription = PushSubscription.find_by!(token: @token)
    assert_equal @user, subscription.user
    assert_equal "sandbox", subscription.environment

    assert_no_difference "PushSubscription.count" do
      post api_v1_push_subscriptions_url,
           params: { token: @token, environment: "production", platform: "ios" },
           headers: @headers,
           as: :json
    end
    assert_equal "production", subscription.reload.environment
  end

  test "requires a read write API key" do
    read_key_value = ApiKey.generate_secure_key
    read_key = ApiKey.create!(
      user: @user,
      name: "Read-only native push test",
      key: read_key_value,
      scopes: [ "read" ],
      source: "mobile"
    )

    post api_v1_push_subscriptions_url,
         params: { token: @token, environment: "sandbox", platform: "ios" },
         headers: api_headers(read_key),
         as: :json

    assert_response :forbidden
  end

  test "rejects malformed tokens" do
    post api_v1_push_subscriptions_url,
         params: { token: "not-a-device-token", environment: "sandbox", platform: "ios" },
         headers: @headers,
         as: :json

    assert_response :unprocessable_entity
  end

  test "rejects an invalid APNs environment" do
    post api_v1_push_subscriptions_url,
         params: { token: @token, environment: "staging", platform: "ios" },
         headers: @headers,
         as: :json

    assert_response :unprocessable_entity
  end

  test "normalizes APNs tokens before lookup and persistence" do
    post api_v1_push_subscriptions_url,
         params: { token: @token.upcase, environment: "sandbox", platform: "ios" },
         headers: @headers,
         as: :json

    assert_response :created
    assert PushSubscription.exists?(token: @token)

    assert_no_difference "PushSubscription.count" do
      post api_v1_push_subscriptions_url,
           params: { token: @token, environment: "sandbox", platform: "ios" },
           headers: @headers,
           as: :json
    end
  end

  test "does not transfer another user's token" do
    other_user = users(:empty)
    subscription = other_user.push_subscriptions.create!(
      token: @token,
      environment: "sandbox",
      platform: "ios",
      last_registered_at: Time.current
    )

    post api_v1_push_subscriptions_url,
         params: { token: @token.upcase, environment: "production", platform: "ios" },
         headers: @headers,
         as: :json

    assert_response :unprocessable_entity
    assert_equal other_user, subscription.reload.user
    assert_equal "sandbox", subscription.environment
  end

  test "returns a controlled response when concurrent token registration conflicts" do
    PushSubscription.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique)

    post api_v1_push_subscriptions_url,
         params: { token: @token, environment: "sandbox", platform: "ios" },
         headers: @headers,
         as: :json

    assert_response :unprocessable_entity
    assert_equal "validation_error", response.parsed_body["error"]
  end

  test "removes the current user's token" do
    subscription = @user.push_subscriptions.create!(
      token: @token,
      environment: "sandbox",
      platform: "ios",
      last_registered_at: Time.current
    )

    assert_difference "PushSubscription.count", -1 do
      delete api_v1_push_subscription_url(subscription), headers: @headers
    end

    assert_response :no_content
  end

  test "does not remove another user's token" do
    subscription = users(:empty).push_subscriptions.create!(
      token: @token,
      environment: "sandbox",
      platform: "ios",
      last_registered_at: Time.current
    )

    delete api_v1_push_subscription_url(subscription), headers: @headers

    assert_response :not_found
    assert PushSubscription.exists?(subscription.id)
  end

  test "requires authentication" do
    post api_v1_push_subscriptions_url,
         params: { token: @token, environment: "sandbox", platform: "ios" },
         as: :json

    assert_response :unauthorized
  end
  test "a device can change users only with its original installation proof" do
    secret = "cd" * 32
    old = PushSubscription.register_for!(user: users(:empty), token: @token,
      environment: "sandbox", platform: "ios", device_key: secret)
    [ nil, "ef" * 32, "malformed" ].each do |proof|
      post api_v1_push_subscriptions_url,
        params: { token: @token, environment: "production", platform: "ios", device_key: proof },
        headers: @headers, as: :json
      assert_response :unprocessable_entity
      assert_equal users(:empty), old.reload.user
    end

    assert_no_difference "PushSubscription.count" do
      post api_v1_push_subscriptions_url,
        params: { token: @token, environment: "production", platform: "ios", device_key: secret },
        headers: @headers, as: :json
      assert_response :created
    end
    replacement = PushSubscription.find_by!(token: @token)
    assert_equal @user, replacement.user
    assert_not_equal old.id, replacement.id
    assert_not PushSubscription.exists?(old.id)
    assert_not response.parsed_body.key?("device_key")
    assert_not response.parsed_body.key?("device_key_digest")
    delete api_v1_push_subscription_url(old.id), headers: @headers
    assert_response :not_found
    assert PushSubscription.exists?(replacement.id)
  end

  test "the original owner can enroll an existing subscription for device continuity" do
    old = @user.push_subscriptions.create!(token: @token, environment: "sandbox", platform: "ios", last_registered_at: Time.current)
    post api_v1_push_subscriptions_url,
      params: { token: @token, environment: "sandbox", platform: "ios", device_key: "cd" * 32 },
      headers: @headers, as: :json
    assert_response :created
    assert_equal old.id, response.parsed_body["id"]
    assert_equal Digest::SHA256.hexdigest("cd" * 32), old.reload.device_key_digest
  end
end
