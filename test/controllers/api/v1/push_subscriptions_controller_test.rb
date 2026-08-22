require "test_helper"

class Api::V1::PushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    key = ApiKey.generate_secure_key
    @api_key = @user.api_keys.create!(
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
    read_key = @user.api_keys.create!(
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
end
