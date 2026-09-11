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
end
