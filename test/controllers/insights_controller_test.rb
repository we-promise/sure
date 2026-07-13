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

  test "turbo prefetch requests do not mark insights read" do
    get insights_url, headers: { "X-Sec-Purpose" => "prefetch" }

    assert_response :success
    assert @insight.reload.active?
  end

  test "dashboard renders the insights feed section with unread badges" do
    get root_url

    assert_response :success
    assert_select "#insights-feed", count: 1
    assert_select "#insights-feed span", text: I18n.t("insights.card.new")
  end

  test "insights feed leads the dashboard for users with a saved order that predates it" do
    @user.update!(preferences: (@user.preferences || {}).merge(
      "section_order" => %w[cashflow_sankey outflows_donut net_worth_chart balance_sheet]
    ))

    get root_url

    assert_response :success
    feed_position = response.body.index('data-section-key="insights_feed"')
    sankey_position = response.body.index('data-section-key="cashflow_sankey"')
    assert feed_position.present? && feed_position < sankey_position,
      "insights_feed should be prepended, not appended, for saved orders that predate it"
  end

  test "dismiss removes the insight from the feed and offers undo via turbo stream" do
    patch dismiss_insight_url(@insight), as: :turbo_stream

    assert_response :success
    assert_match "turbo-stream", response.body
    assert_match undismiss_insight_path(@insight), response.body
    assert @insight.reload.dismissed?
  end

  test "undismiss restores the insight as read and re-renders the list" do
    @insight.dismiss!

    patch undismiss_insight_url(@insight), as: :turbo_stream

    assert_response :success
    assert_match "insights-list", response.body
    assert_match CGI.escapeHTML(@insight.title), response.body
    assert @insight.reload.read?
    assert_nil @insight.dismissed_at
  end

  test "refresh swaps the button into a pending state via turbo stream" do
    assert_enqueued_with(job: GenerateInsightsJob, args: [ { family_id: @user.family_id } ]) do
      post refresh_insights_url, as: :turbo_stream
    end

    assert_response :success
    assert_match "insights-refresh", response.body
    assert_match CGI.escapeHTML(I18n.t("insights.refresh.checking")), response.body
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
    assert_enqueued_with(job: GenerateInsightsJob, args: [ { family_id: @user.family_id } ]) do
      post refresh_insights_url
    end

    assert_redirected_to insights_path
  end
end
