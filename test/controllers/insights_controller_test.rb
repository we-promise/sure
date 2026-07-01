require "test_helper"

class InsightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @insight = insights(:spending_anomaly_dining)
    ensure_tailwind_build
  end

  test "index renders visible insights and marks them read" do
    get insights_url

    assert_response :success
    assert_match CGI.escapeHTML(@insight.title), response.body
    assert @insight.reload.read?
  end

  test "dashboard renders the insights feed section" do
    get root_url

    assert_response :success
    assert_match "insights-feed", response.body
  end

  test "dismiss removes the insight from the feed via turbo stream" do
    patch dismiss_insight_url(@insight), as: :turbo_stream

    assert_response :success
    assert_match "turbo-stream", response.body
    assert @insight.reload.dismissed?
  end

  test "cannot dismiss another family's insight" do
    other_insight = families(:empty).insights.create!(
      insight_type: "idle_cash",
      priority: "low",
      title: "Someone else's insight",
      body: "Body",
      dedup_key: "idle_cash:other:2026-07"
    )

    patch dismiss_insight_url(other_insight), as: :turbo_stream

    assert_response :not_found
    assert other_insight.reload.active?
  end

  test "refresh enqueues insight generation for the family" do
    assert_enqueued_with(job: GenerateInsightsJob) do
      post refresh_insights_url
    end

    assert_redirected_to insights_path
  end
end
