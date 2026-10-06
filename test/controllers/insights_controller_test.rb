require "test_helper"

class InsightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    enable_preview_features
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

  # Unread state is carried by the well's header count, not by a pill on every
  # row. The widget shows three rows, so the pill was usually on all of them,
  # repeating what the header already says and crowding each title.
  test "dashboard insights feed counts unread in its header, without per-row badges" do
    get root_url

    assert_response :success
    assert_select "#insights-feed", count: 1
    assert_select "#insights-feed p", text: /#{Regexp.escape(I18n.t("insights.feed.header_new"))}/
    assert_select "#insights-feed span", text: I18n.t("insights.card.new"), count: 0
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

  # Acknowledging is a quiet action — no undo toast. Acknowledgement only covers
  # the numbers the user saw (see Insight's class comment), so a dismissed
  # insight resurfaces on its own when those numbers move; a toast interrupting
  # every dismissal bought little.
  test "acknowledge clears the insight without an undo toast" do
    patch acknowledge_insight_url(@insight), as: :turbo_stream

    assert_response :success
    assert_match "turbo-stream", response.body
    assert_no_match(/#{Regexp.escape(unacknowledge_insight_path(@insight))}/, response.body)
    assert @insight.reload.acknowledged?
  end

  # The card leaves via a stream, which is silent to a screen reader, and takes
  # the control the user just activated with it. With the toast gone, the shared
  # live region carries that confirmation instead.
  test "acknowledge announces the dismissal in the shared live region" do
    patch acknowledge_insight_url(@insight), as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action=update][target=?]", "aria-announcer" do
      assert_match CGI.escapeHTML(I18n.t("insights.card.acknowledged")), response.body
    end
  end

  test "the live region is present before any stream updates it" do
    get insights_url

    assert_response :success
    assert_select "#aria-announcer[role=status][aria-live=polite]", 1,
      "a live region that arrives with its content is not announced"
  end

  # The card used to leave via `turbo_stream.remove`, which emptied
  # #insights-list without re-rendering the partial that owns the empty state —
  # so dismissing the last insight showed a blank page until reload.
  test "acknowledging the last insight renders the empty state" do
    @user.family.insights.where.not(id: @insight.id).destroy_all

    patch acknowledge_insight_url(@insight), as: :turbo_stream

    assert_response :success
    assert_match "insights-list", response.body
    assert_match CGI.escapeHTML(I18n.t("insights.index.empty.title")), response.body
  end

  # A full dashboard render already drops the section (insights_feed_section sets
  # `visible: @feed_insights.any?`), so the turbo path has to as well — otherwise
  # the section shell lingered with its header above an empty well.
  test "acknowledging the last insight removes the dashboard section" do
    @user.family.insights.where.not(id: @insight.id).destroy_all

    patch acknowledge_insight_url(@insight), as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action=remove][targets=?]", "[data-section-key='insights_feed']"
    assert_select "turbo-stream[action=replace][target=?]", "insights-feed", count: 0
  end

  # The layout renders the lightbulb twice (desktop header, mobile top nav), so
  # the badge is replaced by attribute, not id, and its wrapper stays even at 0
  # so a later stream still has something to target.
  test "layout renders a badge target in both lightbulb copies" do
    get root_url

    assert_response :success
    assert_select "[data-insights-badge]", count: 2
  end

  test "acknowledge refreshes the unread badge in both lightbulb copies" do
    unread = @user.family.insights.active.count
    assert_operator unread, :>, 1, "fixtures need more than one unread insight"

    patch acknowledge_insight_url(@insight), as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action=replace][targets=?]", "[data-insights-badge]" do
      assert_select "template [data-insights-badge]", text: (unread - 1).to_s
    end
  end

  test "acknowledging the last unread insight empties the badge but keeps its target" do
    @user.family.insights.active.where.not(id: @insight.id).update_all(status: "read")

    patch acknowledge_insight_url(@insight), as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action=replace][targets=?]", "[data-insights-badge]" do
      assert_select "template [data-insights-badge]", text: ""
    end
  end

  test "the badge stream still caps the count at 9+" do
    11.times do |i|
      @user.family.insights.create!(insight_type: "idle_cash", priority: "low", status: "active",
        title: "Extra #{i}", body: "body", dedup_key: "idle_cash:cap:#{i}", generated_at: Time.current)
    end

    patch acknowledge_insight_url(@insight), as: :turbo_stream

    assert_select "turbo-stream[action=replace][targets=?]", "[data-insights-badge]" do
      assert_select "template [data-insights-badge]", text: "9+"
    end
  end

  test "unacknowledge refreshes the unread badge" do
    @insight.acknowledge!

    unread = @user.family.insights.active.count

    patch unacknowledge_insight_url(@insight), as: :turbo_stream

    # Undo restores the insight as read, so the unread count holds.
    assert_response :success
    assert_select "turbo-stream[action=replace][targets=?]", "[data-insights-badge]" do
      assert_select "template [data-insights-badge]", text: unread.to_s
    end
  end

  test "unacknowledge restores the insight as read and re-renders the list" do
    @insight.acknowledge!

    patch unacknowledge_insight_url(@insight), as: :turbo_stream

    assert_response :success
    assert_match "insights-list", response.body
    assert_match CGI.escapeHTML(@insight.title), response.body
    assert @insight.reload.read?
    assert_nil @insight.dismissed_at
  end

  # Acknowledging used to be reachable only from /insights, so the dashboard —
  # the surface people actually look at — could show an insight but not clear it.
  test "dashboard feed rows carry an acknowledge control" do
    get root_url

    assert_response :success
    assert_select "#insights-feed form[action=?]", acknowledge_insight_path(@insight)
  end

  # The widget shows the top N, so clearing one has to promote the next into the
  # freed slot rather than leave a gap — hence a re-render, not a row removal.
  test "acknowledge re-renders the dashboard feed so the next insight backfills" do
    family = @user.family
    family.insights.destroy_all

    # One more than the well holds, same priority so `ordered` falls through to
    # generated_at and the sequence is predictable.
    rows = (Insight::FEED_LIMIT + 1).times.map do |i|
      family.insights.create!(
        insight_type: "idle_cash",
        priority: "high",
        status: "active",
        title: "Test insight #{i}",
        body: "body",
        dedup_key: "idle_cash:test:#{i}",
        generated_at: (i + 1).minutes.ago
      )
    end

    patch acknowledge_insight_url(rows.first), as: :turbo_stream

    assert_response :success
    assert_match "insights-feed", response.body
    assert_no_match(/Test insight 0/, response.body)
    assert_match(/Test insight #{Insight::FEED_LIMIT}/, response.body)
  end

  test "refresh swaps the button into a pending state via turbo stream" do
    assert_enqueued_with(job: GenerateInsightsJob, args: [ { family_id: @user.family_id } ]) do
      post refresh_insights_url, as: :turbo_stream
    end

    assert_response :success
    assert_match "insights-refresh", response.body
    assert_match CGI.escapeHTML(I18n.t("insights.refresh.checking")), response.body
  end

  test "cannot acknowledge another family's insight" do
    other_insight = families(:empty).insights.create!(
      insight_type: "idle_cash",
      priority: "low",
      title: "Someone else's insight",
      body: "Body",
      dedup_key: "idle_cash:other:2026-07"
    )

    patch acknowledge_insight_url(other_insight), as: :turbo_stream

    assert_response :not_found
    assert other_insight.reload.active?
  end

  test "refresh enqueues insight generation for the family" do
    assert_enqueued_with(job: GenerateInsightsJob, args: [ { family_id: @user.family_id } ]) do
      post refresh_insights_url
    end

    assert_redirected_to insights_path
  end

  # Preview gate. Insights is opt-in via Settings → Preferences, so a user
  # without the flag reaches none of it — not the page, not the dashboard
  # section, not the top-bar entry, and not the job the refresh action would
  # otherwise enqueue.
  test "redirects users without preview access" do
    disable_preview_features

    get insights_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "refresh does not enqueue generation for users without preview access" do
    disable_preview_features

    assert_no_enqueued_jobs only: GenerateInsightsJob do
      post refresh_insights_url
    end

    assert_redirected_to root_path
  end

  test "acknowledge is blocked for users without preview access" do
    disable_preview_features

    patch acknowledge_insight_url(@insight), as: :turbo_stream

    assert_redirected_to root_path
    assert @insight.reload.active?
  end

  test "dashboard omits the insights feed and top-bar entry without preview access" do
    disable_preview_features

    get root_url

    assert_response :success
    assert_select "#insights-feed", count: 0
    assert_select "a[href=?]", insights_path, count: 0
  end

  test "renders a release reminder with its figure and account link" do
    account = accounts(:depository)
    @user.family.insights.create!(
      insight_type: "account_release", priority: "medium", status: "active",
      title: "Term deposit is released soon", body: "$5,000.00 on Term deposit becomes available on October 15, 2026.",
      facts: { "balance" => "$5,000.00", "days" => 10 },
      metadata: { "account_id" => account.id, "kind" => "upcoming", "release_on" => "2026-10-15" },
      generated_at: Time.current, dedup_key: "account_release:upcoming:#{account.id}:2026-10-15"
    )

    get insights_url

    assert_response :success
    assert_includes response.body, "free in 10 days"
    assert_select "a[href='#{account_path(account)}']", text: I18n.t("insights.actions.account_release")
  end

  private
    def enable_preview_features
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def disable_preview_features
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    end
end
