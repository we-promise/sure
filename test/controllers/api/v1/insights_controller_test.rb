require "test_helper"

class Api::V1::InsightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    key = ApiKey.generate_secure_key
    @api_key = ApiKey.create!(
      user: @user,
      name: "Native insights test",
      key: key,
      scopes: [ "read" ],
      source: "mobile"
    )
    @insight = @user.family.insights.create!(
      insight_type: "idle_cash",
      priority: "medium",
      status: "active",
      title: "Put idle cash to work",
      body: "One account has more cash than usual.",
      generated_at: Time.current,
      dedup_key: "native-insights-test"
    )
  end

  test "lists visible family insights" do
    get api_v1_insights_url, headers: api_headers(@api_key)

    assert_response :success
    payload = response.parsed_body
    row = payload.fetch("insights").find { |insight| insight.fetch("id") == @insight.id }
    assert_equal "idle_cash", row.fetch("type")
    assert_equal "Put idle cash to work", row.fetch("title")
  end

  test "rejects requests without an API key" do
    get api_v1_insights_url

    assert_response :unauthorized
  end

  test "does not expose insights when the API key owner opted out of preview features" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get api_v1_insights_url, headers: api_headers(@api_key)

    assert_response :forbidden
    assert_equal "feature_disabled", response.parsed_body.fetch("error")
  end
  test "acknowledges an insight as read and removes it from the feed" do
    @api_key.update!(scopes: [ "read_write" ])
    patch acknowledge_api_v1_insight_url(@insight), headers: api_headers(@api_key)

    assert_response :no_content
    assert @insight.reload.acknowledged?
    assert_not_nil @insight.read_at
    assert_not_nil @insight.dismissed_at
    get api_v1_insights_url, headers: api_headers(@api_key)
    assert_response :success
    assert_not_includes response.parsed_body.fetch("insights").pluck("id"), @insight.id
  end

  test "acknowledgment is idempotent and does not revive expired insights" do
    @api_key.update!(scopes: [ "read_write" ])
    patch acknowledge_api_v1_insight_url(@insight), headers: api_headers(@api_key)
    dismissed_at = @insight.reload.dismissed_at
    patch acknowledge_api_v1_insight_url(@insight), headers: api_headers(@api_key)
    assert_response :no_content
    assert_equal dismissed_at, @insight.reload.dismissed_at

    @insight.update!(status: :expired)
    patch acknowledge_api_v1_insight_url(@insight), headers: api_headers(@api_key)
    assert_response :no_content
    assert @insight.reload.expired?
  end

  test "acknowledging a read insight preserves its original read timestamp" do
    @api_key.update!(scopes: [ "read_write" ])
    read_at = 1.hour.ago.change(usec: 0)
    @insight.update!(status: :read, read_at: read_at)
    patch acknowledge_api_v1_insight_url(@insight), headers: api_headers(@api_key)
    assert_response :no_content
    assert @insight.reload.acknowledged?
    assert_equal read_at, @insight.read_at
  end

  test "read-only keys cannot acknowledge insights" do
    patch acknowledge_api_v1_insight_url(@insight), headers: api_headers(@api_key)
    assert_response :forbidden
    assert_equal "insufficient_scope", response.parsed_body.fetch("error")
    assert @insight.reload.active?
  end

  test "acknowledgment requires authentication and preview access" do
    patch acknowledge_api_v1_insight_url(@insight)
    assert_response :unauthorized
    @api_key.update!(scopes: [ "read_write" ])
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    patch acknowledge_api_v1_insight_url(@insight), headers: api_headers(@api_key)
    assert_response :forbidden
    assert_equal "feature_disabled", response.parsed_body.fetch("error")
    assert @insight.reload.active?
  end

  test "cannot acknowledge another family's or a hidden account's insight" do
    @api_key.update!(scopes: [ "read_write" ])
    @insight.update!(family: families(:empty))
    patch acknowledge_api_v1_insight_url(@insight), headers: api_headers(@api_key)
    assert_response :not_found
    assert @insight.reload.active?

    @insight.update!(family: @user.family, metadata: { account_id: SecureRandom.uuid })
    patch acknowledge_api_v1_insight_url(@insight), headers: api_headers(@api_key)
    assert_response :not_found
    assert @insight.reload.active?
  end

  test "rejects missing and malformed insight IDs" do
    @api_key.update!(scopes: [ "read_write" ])
    [ SecureRandom.uuid, "invalid" ].each do |id|
      patch acknowledge_api_v1_insight_url(id), headers: api_headers(@api_key)
      assert_response :not_found
    end
  end

  test "guests cannot change the shared insight feed" do
    @api_key.update!(scopes: [ "read_write" ])
    @user.update!(role: :guest)
    patch acknowledge_api_v1_insight_url(@insight), headers: api_headers(@api_key)
    assert_response :forbidden
    assert @insight.reload.active?
  end
end
